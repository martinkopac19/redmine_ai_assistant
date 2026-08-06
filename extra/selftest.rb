# frozen_string_literal: true

# Regresný self-test pre redmine_ai_assistant (Gemini, spoločný admin kľúč).
#
# Spustenie — POZOR na `--user redmine`:
#   docker compose exec --user redmine -e SECRET_KEY_BASE=<key> redmine \
#     rails runner plugins/redmine_ai_assistant/extra/selftest.rb [login]
#
# `docker compose exec` beží ako root, kým Puma ako `redmine`. Bez `--user redmine`
# vzniknú v tmp/cache súbory vlastnené rootom, ktoré appka nedokáže prepísať.
# `SECRET_KEY_BASE` treba dodať aj pre rails runner, aj pre rake — entrypoint ju
# exportuje len hlavnému procesu.
#
# Do Gemini sa odošle jediné volanie so ZÁMERNE NEPLATNÝM kľúčom, ktorým sa overí
# HTTP cesta a mapovanie chýb. Do Redmine sa nezapíše žiadny komentár a nastavenia
# pluginu sa na konci vrátia do pôvodného stavu.

login = ARGV[0].presence || 'martin_kopac'
user  = User.active.find_by(login: login) || User.active.first
abort 'Ziadny aktivny uzivatel.' if user.nil?
User.current = user

def ok(bool)
  bool ? 'OK' : '!! CHYBA'
end

FAKE_KEY = 'AIzaSyTESTKEY-0123456789-selftest-abcd'

puts '=' * 78
puts "  redmine_ai_assistant selftest — user: #{user.login} (##{user.id})"
puts '=' * 78

original = Setting.plugin_redmine_ai_assistant

begin
  # --- 1. registracia a nastavenia -----------------------------------------
  puts "\n[1] Registracia a nastavenia"
  plugin = begin
    Redmine::Plugin.find(:redmine_ai_assistant)
  rescue StandardError
    nil
  end
  puts "  plugin najdeny             : #{ok(plugin.present?)} (#{plugin&.version})"
  s = RedmineAiAssistant.settings
  puts "  model                      : #{s['model']}"
  puts "  max_tokens                 : #{s['max_tokens']}"
  puts "  persona ma {{NAME}}        : #{ok(s['system_prompt'].include?('{{NAME}}'))}"
  persona = RedmineAiAssistant.system_prompt_for(user)
  puts "  persona doplnena menom     : #{ok(persona.include?(user.name) && !persona.include?('{{NAME}}'))}"
  puts "  summary prompt existuje    : #{ok(s['summary_system_prompt'].to_s.length > 100)}"
  puts "  summary limit popisu       : #{s['summary_description_limit']}"
  # POZOR: admin si prompt prepisuje a {{NAME}} v ňom mať nemusí — to je legitímne.
  # Testujeme teda samotné dopĺňanie, nie obsah admin textu.
  probe = RedmineAiAssistant.system_prompt_for(user, 'summary_system_prompt')
  puts "  summary persona bez {{NAME}}: #{ok(!probe.include?('{{NAME}}'))}"
  puts "  {{NAME}} sa doplna menom   : " \
       "#{ok(RedmineAiAssistant::DEFAULT_SUMMARY_PROMPT.include?('{{NAME}}') &&
             probe.include?('{{NAME}}') == false)}"
  puts "  nastaveny prompt ma {{NAME}}: " \
       "#{s['summary_system_prompt'].to_s.include?('{{NAME}}') ? 'ano' : 'nie (vlastny text admina)'}"
  puts "  dva ROZDIELNE prompty      : #{ok(probe != persona)}"

  # --- 2. sifrovanie -------------------------------------------------------
  puts "\n[2] Sifrovanie kluca"
  enc = RedmineAiAssistant::Credentials.encrypt(FAKE_KEY)
  puts "  encrypt nie je plaintext   : #{ok(enc.present? && !enc.include?(FAKE_KEY))}"
  puts "  decrypt round-trip         : #{ok(RedmineAiAssistant::Credentials.decrypt(enc) == FAKE_KEY)}"
  puts "  hint = posledne 4 znaky    : #{ok(RedmineAiAssistant::Credentials.hint(FAKE_KEY) == 'abcd')}"
  puts "  poskodeny payload -> nil   : #{ok(RedmineAiAssistant::Credentials.decrypt('rubbish').nil?)}"

  # --- 3. ukladanie kluca cez KeyStore -------------------------------------
  puts "\n[3] Ukladanie kluca (logika patchu SettingsController)"

  # (a) vyplnene pole -> zasifruje sa
  p1 = ActionController::Parameters.new('api_key' => FAKE_KEY)
  RedmineAiAssistant::KeyStore.merge_into_params!(p1)
  puts "  nove pole -> ciphertext    : #{ok(p1['api_key'].present? && !p1['api_key'].include?(FAKE_KEY))}"
  puts "  ulozi sa hint 'abcd'       : #{ok(p1['api_key_hint'] == 'abcd')}"

  Setting.plugin_redmine_ai_assistant = original.to_h.merge(
    'api_key' => p1['api_key'], 'api_key_hint' => p1['api_key_hint'],
    'enabled' => '1'
  )
  puts "  KeyStore.present?          : #{ok(RedmineAiAssistant::KeyStore.present?)}"
  puts "  KeyStore.api_key dekoduje  : #{ok(RedmineAiAssistant::KeyStore.api_key == FAKE_KEY)}"
  puts "  KeyStore.hint              : #{RedmineAiAssistant::KeyStore.hint} #{ok(RedmineAiAssistant::KeyStore.hint == 'abcd')}"

  # (b) prazdne pole -> existujuci kluc zostava
  p2 = ActionController::Parameters.new('api_key' => '')
  RedmineAiAssistant::KeyStore.merge_into_params!(p2)
  puts "  prazdne pole nezmaze kluc  : #{ok(p2['api_key'].present? &&
                                            RedmineAiAssistant::Credentials.decrypt(p2['api_key']) == FAKE_KEY)}"

  # (c) zaskrtnute "zmazat" -> kluc sa zmaze
  p3 = ActionController::Parameters.new('api_key' => '', 'api_key_clear' => '1')
  RedmineAiAssistant::KeyStore.merge_into_params!(p3)
  puts "  clear zmaze kluc           : #{ok(p3['api_key'] == '' && p3['api_key_hint'] == '')}"
  puts "  clear param sa nepretaci   : #{ok(!p3.key?('api_key_clear'))}"

  # --- 4. KLUC NESMIE BYT V HTML ------------------------------------------
  puts "\n[4] Kluc v HTML (Inspect element)"
  html = ApplicationController.render(partial: 'settings/ai_assistant',
                                      locals: { settings: RedmineAiAssistant.settings })
  puts "  cely kluc NIE JE v HTML    : #{ok(!html.include?(FAKE_KEY))}"
  ciphertext = RedmineAiAssistant.setting('api_key').to_s
  puts "  ani ciphertext NIE JE v HTML: #{ok(ciphertext.present? && !html.include?(ciphertext))}"
  puts "  pole je bez value=         : #{ok(html.include?('id="ai_assistant_api_key"') &&
                                            !html.match?(/id="ai_assistant_api_key"[^>]*value=/))}"
  puts "  zobrazuje sa len hint      : #{ok(html.include?('abcd'))}"
  puts "  gdpr_ack checkbox je zruseny: #{ok(!html.include?('gdpr_ack'))}"
  puts "  GDPR poznamka je zrusena   : #{ok(!html.include?('GDPR'))}"

  # --- 5. gating ----------------------------------------------------------
  puts "\n[5] Gating (zapnute + kluc)"
  base = RedmineAiAssistant.settings
  Setting.plugin_redmine_ai_assistant = base.merge('enabled' => '0')
  puts "  vypnute -> usable? false   : #{ok(RedmineAiAssistant.usable? == false)}"
  Setting.plugin_redmine_ai_assistant = base.merge('enabled' => '1', 'api_key' => '')
  puts "  bez kluca -> false         : #{ok(RedmineAiAssistant.usable? == false)}"
  Setting.plugin_redmine_ai_assistant = base.merge('enabled' => '1')
  puts "  vsetko splnene -> true     : #{ok(RedmineAiAssistant.usable? == true)}"
  # Zrusene nastavenie sa uz nesmie nikde citat ani renderovat.
  Setting.plugin_redmine_ai_assistant = base.merge('enabled' => '1', 'gdpr_ack' => '0')
  puts "  stary gdpr_ack neblokuje   : #{ok(RedmineAiAssistant.usable? == true)}"
  Setting.plugin_redmine_ai_assistant = base.merge('enabled' => '1')

  # --- 6. GDPR filtre ----------------------------------------------------
  puts "\n[6] GDPR filtre"
  issue = Issue.visible(user).where(is_private: false)
               .joins(:journals)
               .where(journals: { private_notes: true })
               .where.not(journals: { notes: [nil, ''] })
               .distinct.first
  if issue
    body = RedmineAiAssistant::ContextBuilder.suggestion_prompt(issue, RedmineAiAssistant.settings)
    sbody = RedmineAiAssistant::ContextBuilder.summary_prompt(issue, RedmineAiAssistant.settings)
    priv = issue.journals.where(private_notes: true).where.not(notes: [nil, '']).pluck(:notes)
    leaked = priv.select { |n| body.include?(n.to_s.strip) }
    # Zhrnutie ide tou istou cestou, ale kontrolujeme ho SAMOSTATNE — filtre sú
    # v spoločnej časti, no práve preto sa nesmie stať, že sa jedna vetva rozíde.
    leaked_sum = priv.select { |n| sbody.include?(n.to_s.strip) }
    puts "  uloha ##{issue.id}, privatnych poznamok: #{priv.size}"
    puts "  ziadna privatna v prompte  : #{ok(leaked.empty?)}"
    puts "  ziadna privatna v zhrnuti  : #{ok(leaked_sum.empty?)}"
  end

  public_issue = Issue.visible(user).where(is_private: false)
                      .joins(:journals)
                      .where(journals: { private_notes: false })
                      .where.not(journals: { notes: [nil, ''] })
                      .group('issues.id').having('count(journals.id) >= 2').first
  if public_issue
    pbody = RedmineAiAssistant::ContextBuilder.suggestion_prompt(public_issue, RedmineAiAssistant.settings)
    puts "  verejne komentare v prompte: #{ok(pbody.include?('## Komentáře'))} (##{public_issue.id})"
  end

  priv_issue = Issue.where(is_private: true).first ||
               Issue.new(is_private: true, project: issue&.project, subject: 'synthetic')
  puts "  privatna uloha vylucena    : #{ok(RedmineAiAssistant.available_for?(priv_issue) == false)}"

  # Do kontextu musia ist VSETKY verejne komentare, nielen prvych N.
  chatty = Issue.visible(user).where(is_private: false)
                .joins(:journals)
                .where(journals: { private_notes: false })
                .where.not(journals: { notes: [nil, ''] })
                .group('issues.id').having('count(journals.id) >= 8').first
  if chatty
    n = chatty.journals.where(private_notes: false).where.not(notes: [nil, '']).count
    cbody = RedmineAiAssistant::ContextBuilder.suggestion_prompt(chatty, RedmineAiAssistant.settings)
    in_prompt = cbody.scan(/^\*\*.+ \(\d{4}-\d{2}-\d{2}\):\*\*$/).size
    puts "  vsetky komentare v kontexte: #{ok(in_prompt == n)} (##{chatty.id}: #{in_prompt} z #{n})"
    puts "  nazov ulohy v kontexte     : #{ok(cbody.include?(chatty.subject.to_s))}"
  else
    puts '  (nenasla sa uloha s 8+ verejnymi komentarmi)'
  end

  # --- 6b. zhrnutie: prompt a limity --------------------------------------
  puts "\n[6b] Prompt pre zhrnutie"
  # POZOR: `issues.description` s prefixom — Issue.visible joinuje projects
  # a enabled_modules, a `description` má aj projects → PG::AmbiguousColumn.
  long = Issue.visible(user).where(is_private: false)
              .where('LENGTH(issues.description) > 2000').first
  if long
    st = RedmineAiAssistant.settings
    reply  = RedmineAiAssistant::ContextBuilder.suggestion_prompt(long, st)
    summ   = RedmineAiAssistant::ContextBuilder.summary_prompt(long, st)
    # Vlastný limit sa musí naozaj aplikovať: 600 vs 4000 znakov popisu.
    puts "  uloha ##{long.id}, popis #{long.description.to_s.length} znakov"
    puts "  zhrnutie ma dlhsi kontext  : #{ok(summ.length > reply.length)} " \
         "(#{summ.length} vs #{reply.length})"
    # V zhrnutí NESMIE byť blok „Zadání" — inštrukciu nesie system prompt.
    puts "  zhrnutie bez bloku Zadani  : #{ok(!summ.include?('## Zadání'))}"
    puts "  odpoved MA blok Zadani     : #{ok(reply.include?('## Zadání'))}"
    # Limit 0 = neskracovať.
    full = RedmineAiAssistant::ContextBuilder.summary_prompt(
      long, st.merge('summary_description_limit' => '0')
    )
    puts "  limit 0 = cely popis       : #{ok(full.include?(long.description.to_s.strip))}"
  else
    puts '  (nenasla sa uloha s popisom > 2000 znakov)'
  end

  # Refaktor nesmie zmeniť prompt pre odpoveď — porovnanie so zloženim „ručne".
  if public_issue
    st = RedmineAiAssistant.settings
    rebuilt = RedmineAiAssistant::ContextBuilder.suggestion_prompt(public_issue, st)
    puts "  odpoved: hlavicka + popis  : #{ok(rebuilt.start_with?("# Úloha ##{public_issue.id}:"))}"
    puts "  odpoved: cesky pokyn       : #{ok(rebuilt.include?('Odpověď musí být v češtině'))}"
  end

  # --- 7. routy a lokalizacie ---------------------------------------------
  puts "\n[7] Routy"
  %w[ai_assistant_suggest_path ai_assistant_summary_path].each do |helper|
    puts "  #{helper.ljust(34)} #{ok(Rails.application.routes.url_helpers.respond_to?(helper))}"
  end
  [:ai_assistant_credential_path, :ai_assistant_translate_path,
   :ai_assistant_translate_note_path].each do |gone|
    puts "  zrusena #{gone.to_s.ljust(33)} #{ok(!Rails.application.routes.url_helpers.respond_to?(gone))}"
  end

  puts "\n[8] Lokalizacie"
  keys = %w[working cancel button_suggest
            button_summary summary_working summary_title close
            error_disabled error_no_key error_invalid_key error_unavailable
            error_rate_limited error_provider_rate_limited error_blocked error_truncated
            error_timeout error_unreachable error_generic
            legend_key legend_general legend_reply reply_note legend_summary summary_note
            setting_api_key setting_api_key_info setting_api_key_clear
            setting_api_key_clear_info key_set key_missing
            setting_enabled setting_enabled_info
            setting_model setting_model_info setting_max_tokens setting_max_tokens_info
            setting_rate_limit setting_rate_limit_info
            setting_description_limit setting_description_limit_info
            setting_changeset_limit setting_system_prompt setting_system_prompt_info
            setting_summary_description_limit setting_summary_description_limit_info
            setting_summary_system_prompt setting_summary_system_prompt_info]
  %w[sk cs en].each do |loc|
    missing = keys.reject { |k| I18n.t("ai_assistant.#{k}", locale: loc, default: nil).present? }
    puts "  #{loc}: #{missing.empty? ? 'OK' : "!! chybaju: #{missing.join(', ')}"}"
  end

  # --- 9. render partialov -------------------------------------------------
  puts "\n[9] Render partialov"
  if issue
    h = ApplicationController.render(partial: 'ai_assistant/issue_actions',
                                     locals: { issue: issue })
    puts "  issue_actions              : OK (#{h.length} B), tlacidlo #{ok(h.include?('data-raa="suggest"'))}"
    puts "  krizik na zrusenie         : #{ok(h.include?('data-raa="cancel"') && h.include?('hidden'))}"

    b = ApplicationController.render(partial: 'ai_assistant/issue_summary_button',
                                     locals: { issue: issue })
    puts "  summary_button             : OK (#{b.length} B), tlacidlo #{ok(b.include?('data-raa="summary"'))}"
    # Odkaz s triedou .icon, nie <button> — inak by nezdedil vzhľad z témy.
    puts "  je to <a class='icon'>     : #{ok(b.include?('<a href="#" class="icon') &&
                                              !b.include?('<button'))}"
    puts "  ikona prutika (inline SVG) : #{ok(b.include?('<svg') && b.include?('currentColor'))}"
    puts "  data-issue-label pre nadpis: #{ok(b.include?('data-issue-label'))}"
  end

  # Konfiguračná stránka musí obsahovať OBA prompty a oba limity.
  cfg = ApplicationController.render(partial: 'settings/ai_assistant',
                                     locals: { settings: RedmineAiAssistant.settings })
  puts "  konfig: prompt odpovede    : #{ok(cfg.include?('settings[system_prompt]'))}"
  puts "  konfig: prompt zhrnutia    : #{ok(cfg.include?('settings[summary_system_prompt]'))}"
  puts "  konfig: limit odpovede     : #{ok(cfg.include?('settings[description_limit]'))}"
  puts "  konfig: limit zhrnutia     : #{ok(cfg.include?('settings[summary_description_limit]'))}"

  # --- 10. Gemini klient: realna HTTP cesta -------------------------------
  puts "\n[10] Gemini klient — HTTP cesta (zamerne neplatny kluc)"
  begin
    RedmineAiAssistant::GeminiClient.new('AIzaSy-invalid-key-for-selftest')
                                    .complete('You are a test.', 'Say OK.')
    puts '  !! neplatny kluc NEVYHODIL chybu'
  rescue RedmineAiAssistant::GeminiClient::AuthError
    puts '  neplatny kluc -> AuthError : OK (endpoint aj hlavicka su spravne)'
  rescue RedmineAiAssistant::GeminiClient::Error => e
    puts "  ina chyba klienta          : #{e.class} (#{e.message})"
  end

  # --- 11. cache sa musi zneplatnit po zmene nastaveni ---------------------
  #
  # Regresia, ktora uz raz nastala: cache key drzal ulohu a uzivatela, ale nie to,
  # co sa naozaj odosiela. Admin zmenil prompt, klikol a hodinu dostaval staru
  # odpoved — v domneni, ze nastavenie nefunguje. Plati pre OBA endpointy, lebo
  # obe akcie idu cez tu istu metodu.
  #
  # MUSI byt az za sekciou [10]: prepisujeme `complete`, cim by sme test realnej
  # HTTP cesty znefunkcnili.
  puts "\n[11] Cache po zmene nastaveni (oba endpointy)"
  target = public_issue || issue
  if target
    calls = 0
    # Text musi byt unikatny PRE KAZDY BEH: inak by sa novo vygenerovana odpoved
    # zhodovala s odpovedou, ktoru v cache nechal predchadzajuci beh, a test by
    # falosne padal. Meriame preto pocet volani, nie obsah.
    run_id = SecureRandom.hex(4)
    RedmineAiAssistant::GeminiClient.class_eval do
      define_method(:complete) { |*_a, **_k| calls += 1; "ODPOVED #{run_id} #{calls}" }
    end
    ApplicationController.prepend(Module.new { define_method(:user_setup) { User.current = user } })
    sess = ActionDispatch::Integration::Session.new(Rails.application)

    fire = lambda do |path|
      sess.get "/issues/#{target.id}"
      tok = sess.response.body[/name="csrf-token" content="([^"]+)"/, 1]
      sess.post path, :params => { :issue_id => target.id }.to_json,
                :headers => { 'CONTENT_TYPE' => 'application/json', 'X-CSRF-Token' => tok.to_s }
      begin
        JSON.parse(sess.response.body)
      rescue StandardError
        {}
      end
    end

    base = RedmineAiAssistant.settings
    [['/ai_assistant/suggest', 'system_prompt', 'odpoved '],
     ['/ai_assistant/summary', 'summary_system_prompt', 'zhrnutie']].each do |path, key, label|
      Setting.plugin_redmine_ai_assistant = base
      first = fire.call(path)

      # (a) rovnake nastavenia => ziadne nove volanie (a teda ziadny plateny request)
      before = calls
      cached = fire.call(path)
      no_new_call = (calls == before)
      puts "  #{label}: bez zmeny z cache : #{ok(no_new_call &&
                                                 cached['text'] == first['text'] &&
                                                 cached['cached'] == true)}"

      # (b) zmena promptu => MUSI vzniknut nove volanie
      before = calls
      Setting.plugin_redmine_ai_assistant = base.merge(key => "Zmeneny prompt #{run_id}.")
      after = fire.call(path)
      puts "  #{label}: po zmene promptu  : #{ok(calls == before + 1 &&
                                                 after['cached'].nil? &&
                                                 after['text'].present?)}"
    end
    Setting.plugin_redmine_ai_assistant = base
  else
    puts '  (nenasla sa vhodna uloha)'
  end
rescue StandardError => e
  puts "  !! SPADLO: #{e.class}: #{e.message}"
  puts "     #{e.backtrace.first(5).join("\n     ")}"
ensure
  Setting.plugin_redmine_ai_assistant = original
  puts "\n  (nastavenia pluginu vratene do povodneho stavu)"
end

puts "\n" + '=' * 78
