# frozen_string_literal: true

require 'net/http'
require 'json'
require 'cgi'

module RedmineAiAssistant
  # Čítanie z GitLabu. Výhradne GET a výhradne token so scope `read_api` —
  # plugin nemá dôvod do GitLabu čokoľvek zapisovať a token bez zápisu je
  # jediná vec, ktorá to garantuje aj keby sa v kóde niekedy stala chyba.
  #
  # Odpovede sa cachujú: jeden návrh odpovede si vypýta merge request, jeho
  # diskusie aj diff, a človek klikne aj dvakrát. Bez cache by to bolo šesť
  # volaní GitLabu na jedno kliknutie.
  class GitlabClient
    class Error < StandardError; end

    OPEN_TIMEOUT = 5
    READ_TIMEOUT = 20
    CACHE_TTL = 15.minutes

    # Diff jedného MR môže mať stovky kB (namerané: 59 kB pri 78 súboroch).
    # Toto je strop na SUROVÚ odpoveď, nie na to, čo ide do promptu — ten si
    # reže CodeContext. Chráni pamäť pred patologickým MR.
    MAX_RESPONSE_BYTES = 4 * 1024 * 1024

    def initialize(base_url:, token:)
      @base = base_url.to_s.strip.sub(%r{/+\z}, '')
      @token = token.to_s.strip
    end

    def configured?
      @base.present? && @token.present?
    end

    # Host, na ktorý sa smie posielať token. Odkaz na MR je v úlohe obyčajné
    # textové pole, ktoré môže vyplniť ktokoľvek — bez tejto kontroly by stačilo
    # zapísať odkaz na cudziu doménu a token by odišiel tam.
    def host
      URI(@base).host
    rescue StandardError
      nil
    end

    def merge_request(project, iid)
      get("/projects/#{enc(project)}/merge_requests/#{enc_seg(iid)}")
    end

    def merge_request_changes(project, iid)
      get("/projects/#{enc(project)}/merge_requests/#{enc_seg(iid)}/changes")
    end

    def merge_request_discussions(project, iid)
      get("/projects/#{enc(project)}/merge_requests/#{enc_seg(iid)}/discussions?per_page=100")
    end

    def commit(project, sha)
      get("/projects/#{enc(project)}/repository/commits/#{enc_seg(sha)}")
    end

    def commit_diff(project, sha)
      get("/projects/#{enc(project)}/repository/commits/#{enc_seg(sha)}/diff")
    end

    # Hľadanie v kóde projektu. Globálne `/search` vyžaduje na GitLabe Advanced
    # Search (Elasticsearch); hľadanie v rámci projektu funguje aj bez neho,
    # preto sa hľadá vždy per projekt.
    def search_blobs(project, query, per_page)
      get("/projects/#{enc(project)}/search?scope=blobs" \
          "&search=#{CGI.escape(query.to_s)}&per_page=#{per_page.to_i}")
    end

    private

    # Cesta projektu ('previo/previo2') musí ísť do URL zakódovaná ako jeden segment.
    def enc(project)
      CGI.escape(project.to_s)
    end

    def enc_seg(value)
      CGI.escape(value.to_s)
    end

    def get(path)
      raise Error, 'gitlab_not_configured' unless configured?

      Rails.cache.fetch(cache_key(path), :expires_in => CACHE_TTL) { perform_get(path) }
    end

    def cache_key(path)
      "ai_assistant/gitlab/#{Digest::SHA256.hexdigest("#{@base}|#{@token}|#{path}")}"
    end

    def perform_get(path)
      uri = URI("#{@base}/api/v4#{path}")
      req = Net::HTTP::Get.new(uri)
      req['PRIVATE-TOKEN'] = @token
      req['Accept'] = 'application/json'

      res = Net::HTTP.start(uri.host, uri.port,
                            :use_ssl => uri.scheme == 'https',
                            :open_timeout => OPEN_TIMEOUT,
                            :read_timeout => READ_TIMEOUT) { |http| http.request(req) }

      handle(res)
    rescue Net::OpenTimeout, Net::ReadTimeout
      raise Error, 'timeout'
    rescue SocketError, Errno::ECONNREFUSED, Errno::EHOSTUNREACH, OpenSSL::SSL::SSLError => e
      # Toto je očakávaný stav mimo firemnej siete: GitLab má whitelist IP.
      raise Error, "unreachable (#{e.class})"
    end

    def handle(res)
      case res.code.to_i
      when 200
        body = res.body.to_s
        raise Error, 'response_too_large' if body.bytesize > MAX_RESPONSE_BYTES

        JSON.parse(body)
      when 401, 403 then raise Error, 'unauthorized'
      when 404 then raise Error, 'not_found'
      when 429 then raise Error, 'rate_limited'
      else raise Error, "http_#{res.code}"
      end
    rescue JSON::ParserError
      raise Error, 'invalid_json'
    end
  end
end
