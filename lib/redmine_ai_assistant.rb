# frozen_string_literal: true

module RedmineAiAssistant
  # Persona NIE JE hardcodovaná na konkrétne meno — {{NAME}} sa dopĺňa
  # z User.current pri každom volaní.
  DEFAULT_SYSTEM_PROMPT = <<~PROMPT
    Jsi {{NAME}}, člen týmu Previo.cz. Previo je cloudový hotelový systém (PMS)
    pro hotely a penziony v ČR, na Slovensku a ve střední Evropě.

    Odpovídáš česky, profesionálně a věcně, ale přátelsky. Piš konkrétně a k věci,
    maximálně 200 slov. Výstupem je čistý text připravený k vložení do Redmine —
    žádný úvod typu "Zde je návrh odpovědi", žádné uvozovky okolo celé odpovědi.

    Pokud něco nevíš, přiznej to a napiš, co ověříš nebo koho se zeptáš.
    Nekopíruj zadání ani předchozí komentáře zpět do odpovědi.
  PROMPT

  DEFAULTS = {
    'enabled'             => '0',
    'api_key'             => '',
    'api_key_hint'        => '',
    'model'               => 'gemini-3.6-flash',
    'max_tokens'          => '2048',
    'description_limit'   => '600',
    'changeset_limit'     => '5',
    'rate_limit_per_hour' => '30',
    'system_prompt'       => DEFAULT_SYSTEM_PROMPT
  }.freeze

  class << self
    def settings
      stored = Setting.plugin_redmine_ai_assistant || {}
      DEFAULTS.merge(stored.to_h.reject { |_k, v| v.nil? || v.to_s.empty? })
    rescue StandardError
      DEFAULTS.dup
    end

    def setting(key)
      settings[key.to_s]
    end

    # Plugin je použiteľný len ak ho admin zapol a vložil spoločný Gemini kľúč.
    # Vypnuté je bezpečný default.
    def enabled?
      setting('enabled').to_s == '1'
    end

    def usable?
      enabled? && KeyStore.present?
    end

    # Tlačidlá sa zobrazia len ak: plugin je použiteľný, užívateľ je prihlásený,
    # úloha nie je privátna a užívateľ ju vidí.
    # Privátne úlohy sú vylúčené kvôli GDPR — ich obsah sa do externej služby
    # neposiela vôbec, nezávisle na právach.
    def available_for?(issue, user = User.current)
      return false unless usable?
      return false unless user&.logged?
      return false if issue.nil? || issue.is_private?

      issue.visible?(user)
    rescue StandardError
      false
    end

    # Memoizácia v rámci requestu: memoizujeme na objekte User.current, ktorý
    # Redmine vytvára nanovo pri každom requeste (user_setup → User.active
    # .find_by_id), takže je to request-scoped a nehrozí stale cache medzi
    # requestami ani medzi užívateľmi.
    def available_for_memo?(issue)
      return false if issue.nil? || issue.id.nil?

      user = User.current
      memo = user.instance_variable_get(:@raa_available) || {}
      unless memo.key?(issue.id)
        memo[issue.id] = available_for?(issue, user)
        user.instance_variable_set(:@raa_available, memo)
      end
      memo[issue.id]
    end

    def system_prompt_for(user)
      setting('system_prompt').to_s.gsub('{{NAME}}', user&.name.to_s)
    end

    def rate_limit_key(user)
      ['ai_assistant_rate', user.id, Time.zone.now.strftime('%Y%m%d%H')].join(':')
    end

    # Vracia true, ak je volanie povolené (a zvýši počítadlo).
    #
    # Používa Rails.cache.increment, nie read-then-write: to druhé má race
    # condition, ktorou sa dá limit obísť paralelnými requestami. FileStore
    # increment je atomický v rámci procesu; pri viacerých procesoch je limit
    # mierne priestrelný, ale na ochranu nákladov to stačí.
    #
    # Limit je per užívateľ, ale platí sa zo SPOLOČNÉHO firemného kľúča, takže
    # chráni rozpočet Previa, nie peňaženku jednotlivca.
    def consume_rate_limit!(user)
      limit = setting('rate_limit_per_hour').to_i
      return true if limit <= 0

      used = Rails.cache.increment(rate_limit_key(user), 1, :expires_in => 1.hour).to_i
      used <= limit
    end
  end
end
