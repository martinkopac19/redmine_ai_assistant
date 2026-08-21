# frozen_string_literal: true

require 'net/http'
require 'json'

module RedmineAiAssistant
  # Minimálny klient Gemini API (Google AI) cez Net::HTTP.
  #
  # Bez gemu: pridanie PluginGemfile znamená bundle install v kontejneri pri
  # každom starte, a celé volanie je jeden POST.
  #
  # Kľúč sa posiela HLAVIČKOU x-goog-api-key, nie ako ?key= v URL — inak by
  # skončil v access logoch, proxy logoch a v Rails logu request path.
  class GeminiClient
    BASE_URL = 'https://generativelanguage.googleapis.com/v1beta/models'

    class Error < StandardError; end
    class AuthError < Error; end
    class RateLimitError < Error; end
    class BlockedError < Error; end
    class TruncatedError < Error; end
    class InvalidJsonError < Error; end

    def initialize(api_key, settings = RedmineAiAssistant.settings)
      @api_key  = api_key
      @settings = settings
    end

    # Vracia text odpovede. Pri chybe vyhodí jednu z Error tried.
    def complete(system_prompt, user_prompt, max_tokens: nil)
      body = {
        :systemInstruction => { :parts => [{ :text => system_prompt.to_s }] },
        :contents          => [{ :role => 'user',
                                 :parts => [{ :text => user_prompt.to_s }] }],
        :generationConfig  => {
          :maxOutputTokens => (max_tokens || @settings['max_tokens']).to_i
        }
      }

      parse(post(body))
    end

    # Vracia Hash. `schema` je JSON schéma v tvare, aký chce Gemini
    # (responseSchema) — model tým dostane formu odpovede ako súčasť requestu,
    # nie ako prosbu v prompte.
    #
    # Aj tak sa parsuje obranne a s JEDNÝM retry: responseSchema znižuje
    # pravdepodobnosť nevalidného JSON-u, ale negarantuje ju (typicky pri
    # dosiahnutí limitu tokenov prijde odrezaný objekt). Retry je jeden, nie
    # viac — platí sa za každé volanie a druhé zlyhanie znamená skutočný problém.
    def complete_json(system_prompt, user_prompt, schema, max_tokens: nil)
      body = {
        :systemInstruction => { :parts => [{ :text => system_prompt.to_s }] },
        :contents          => [{ :role => 'user',
                                 :parts => [{ :text => user_prompt.to_s }] }],
        :generationConfig  => {
          :maxOutputTokens  => (max_tokens || @settings['max_tokens']).to_i,
          :responseMimeType => 'application/json',
          :responseSchema   => schema
        }
      }

      attempts = 0
      loop do
        attempts += 1
        text, finish = extract(post(body))
        check_empty(text, finish)

        begin
          data = JSON.parse(strip_fence(text))
          raise JSON::ParserError, 'not_an_object' unless data.is_a?(Hash)

          return data
        rescue JSON::ParserError => e
          # Odrezaný JSON takmer vždy znamená vyčerpaný limit tokenov, nie chybu
          # modelu — a u modelov s uvažovaním sa limit delí medzi uvažovanie
          # a odpoveď, takže sa vyčerpá ľahko. Opakovanie by skončilo rovnako,
          # preto konkrétna chyba „zvýš limit" namiesto „neplatný formát".
          raise TruncatedError, 'max_tokens' if finish == 'MAX_TOKENS'

          if attempts >= 2
            Rails.logger.error("[ai_assistant] model nevratil validny JSON: #{e.message}")
            raise InvalidJsonError, 'invalid_json'
          end
          Rails.logger.warn("[ai_assistant] neplatny JSON, opakujem: #{e.message}")
        end
      end
    end

    private

    # Pri responseMimeType by fence prísť nemal, ale keď príde, je to lacnejšie
    # odstrániť než minúť ďalšie volanie na retry.
    def strip_fence(text)
      text.to_s.strip.sub(/\A```(?:json)?\s*/i, '').sub(/```\z/, '')
    end

    def model
      @settings['model'].to_s.presence || DEFAULTS['model']
    end

    def endpoint
      URI("#{BASE_URL}/#{model}:generateContent")
    end

    def post(body)
      uri = endpoint
      req = Net::HTTP::Post.new(uri)
      req['x-goog-api-key'] = @api_key
      req['content-type']   = 'application/json'
      req.body = JSON.dump(body)

      Net::HTTP.start(uri.host, uri.port,
                      :use_ssl      => true,
                      :open_timeout => 10,
                      :read_timeout => 120) { |http| http.request(req) }
    rescue Net::OpenTimeout, Net::ReadTimeout
      raise Error, 'timeout'
    rescue SocketError, Errno::ECONNREFUSED, OpenSSL::SSL::SSLError
      raise Error, 'unreachable'
    end

    def parse(response)
      text, finish = extract(response)
      check_empty(text, finish)
      text
    end

    # U modelov s uvažovaním sa maxOutputTokens delí medzi uvažovanie a odpoveď,
    # takže pri nízkom limite môže prísť prázdny text s finishReason MAX_TOKENS.
    def check_empty(text, finish)
      raise TruncatedError, 'max_tokens' if text.empty? && finish == 'MAX_TOKENS'
      raise Error, 'empty_response' if text.empty?
    end

    # Vracia [text, finishReason]. Volajúci sa rozhodne, čo s prázdnym alebo
    # odrezaným výstupom — pri texte je čiastočná odpoveď použiteľná, pri JSON-e nie.
    def extract(response)
      code = response.code.to_i
      data = begin
        JSON.parse(response.body.to_s)
      rescue JSON::ParserError
        {}
      end

      check_http_error(code, data) unless code.between?(200, 299)

      # Bezpečnostné filtre Gemini: prompt zablokovaný ešte pred generovaním.
      raise BlockedError, data.dig('promptFeedback', 'blockReason').to_s if
        data.dig('promptFeedback', 'blockReason').present?

      candidate = Array(data['candidates']).first
      raise BlockedError, 'no_candidates' if candidate.nil?

      finish = candidate['finishReason'].to_s
      raise BlockedError, finish if %w[SAFETY BLOCKLIST PROHIBITED_CONTENT RECITATION].include?(finish)

      text = Array(candidate.dig('content', 'parts'))
             .map { |p| p['text'].to_s }
             .join
             .strip

      [text, finish]
    end

    def check_http_error(code, data)
      message = data.dig('error', 'message').to_s
      status  = data.dig('error', 'status').to_s

      raise AuthError, message.presence || 'invalid_key' if
        [401, 403].include?(code) || status == 'UNAUTHENTICATED' ||
        status == 'PERMISSION_DENIED' || message.include?('API key')

      raise RateLimitError, message.presence || 'rate_limited' if
        code == 429 || status == 'RESOURCE_EXHAUSTED'

      raise Error, message.presence || "HTTP #{code}"
    end
  end
end
