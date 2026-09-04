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

  # --- 6c. jazyk zhrnutia ---------------------------------------------------
  puts "\n[6c] Jazyk zhrnutia (My account)"
  saved_lang = user.language
  begin
    RedmineAiAssistant.settings # nahriatie
    langs = { 'cs' => 'e', 'en' => 'E', 'hu' => 'M', 'pl' => 'P' }
    labels = langs.keys.map do |code|
      user.update_columns(:language => code)
      RedmineAiAssistant.language_label(User.find(user.id))
    end
    puts "  kazdy jazyk da iny popis   : #{ok(labels.uniq.size == labels.size)} (#{labels.join(', ')})"

    # Zastupny znak sa musi naozaj nahradit, a to v ULOZENOM prompte, nie v defaulte.
    user.update_columns(:language => 'hu')
    u = User.find(user.id)
    prompt = RedmineAiAssistant.system_prompt_for(u, 'summary_system_prompt')
    puts "  {{LANG}} v prompte nezostal: #{ok(!prompt.include?('{{LANG}}'))}"
    # Kontroluj presne ten popis, ktory sa do promptu doplna — nie kod jazyka.
    # Kod v popise nemusi byt: `general_lang_name` vracia „Hungarian (Magyar)".
    puts "  prompt hovori madarsky     : #{ok(prompt.include?(RedmineAiAssistant.language_label(u)))}"

    user.update_columns(:language => 'cs')
    cs_prompt = RedmineAiAssistant.system_prompt_for(User.find(user.id), 'summary_system_prompt')
    puts "  iny jazyk = iny prompt     : #{ok(cs_prompt != prompt)}"

    # Cache nesmie vratit zhrnutie v cudzom jazyku: kluc obsahuje odtlacok promptu.
    fp = lambda { |txt| Digest::MD5.hexdigest([txt, 'x', 'm'].join("\x00"))[0, 10] }
    puts "  cache rozlisi jazyky       : #{ok(fp.call(prompt) != fp.call(cs_prompt))}"

    # Bez jazyka v profile sa berie predvolby instancie, nie prazdny retazec.
    user.update_columns(:language => '')
    puts "  prazdny jazyk = default    : #{ok(RedmineAiAssistant.language_label(User.find(user.id)).present?)}"
  ensure
    user.update_columns(:language => saved_lang)
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
  %w[ai_assistant_suggest_path ai_assistant_summary_path
     ai_assistant_draft_issue_path].each do |helper|
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
            setting_summary_system_prompt setting_summary_system_prompt_info
            button_draft draft_working draft_filled draft_similar draft_questions
            draft_modal_title draft_apply draft_recalc draft_answer_placeholder
            draft_project_changed
            error_draft_empty error_invalid_json
            legend_draft draft_note
            setting_draft_enabled setting_draft_enabled_info
            setting_draft_similar_limit setting_draft_similar_limit_info
            setting_draft_max_tokens setting_draft_max_tokens_info
            setting_draft_translate_keywords setting_draft_translate_keywords_info
            setting_draft_system_prompt setting_draft_system_prompt_info
            button_plan legend_plan plan_note error_plan_empty
            setting_plan_enabled setting_plan_enabled_info
            setting_plan_max_items setting_plan_max_items_info
            setting_plan_max_tokens setting_plan_max_tokens_info
            setting_plan_system_prompt setting_plan_system_prompt_info
            plan_input_label plan_input_placeholder plan_project_lock
            plan_submit plan_refine plan_accept plan_working plan_heading
            plan_parent plan_subtask plan_standalone plan_no_subtasks
            plan_queue_progress plan_queue_next plan_queue_go plan_queue_skip
            plan_queue_cancel plan_queue_dismiss plan_queue_done plan_queue_no_parent
            plan_queue_parent_missing error_plan_no_result]
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
  puts "  konfig: prompt predvyplnenia: #{ok(cfg.include?('settings[draft_system_prompt]'))}"
  puts "  konfig: vypinac predvyplnenia: #{ok(cfg.include?('settings[draft_enabled]'))}"
  puts "  konfig: vypinac planu      : #{ok(cfg.include?('settings[plan_enabled]'))}"
  puts "  konfig: strop poloziek planu: #{ok(cfg.include?('settings[plan_max_items]'))}"
  puts "  konfig: prompt planu       : #{ok(cfg.include?('settings[plan_system_prompt]'))}"

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

  # --- 12. Create with AI: whitelist, schema, validacia --------------------
  # Bez volania Gemini. Podstatna je cast (b): hodnota, ktoru sme modelu
  # NEnabidli, sa NESMIE dostat do formulara.
  puts "\n[12] Create with AI — whitelist, schema, validacia"
  # POZOR: sekcia [11] pusta skutocne HTTP requesty cez Integration::Session a te
  # po sebe necha `User.current` prestaveny (typicky na Anonymous). Bez tohto
  # riadku by `allowed_to?(:add_issues, …)` bolo false a render partialu by
  # falosne padal.
  User.current = user
  draft_project = Project.active.detect { |p| p.issue_categories.any? && p.trackers.any? } ||
                  Project.active.first
  if draft_project
    dopts = RedmineAiAssistant::IssueDraft.options(
      draft_project, { subject: 'test dlouhe jmeno hosta', description: '' }
    )
    puts "  #{draft_project.identifier}: trackery=#{dopts[:trackers].size} " \
         "kategorie=#{dopts[:categories].size} povinne_cf=#{dopts[:custom_fields].size} " \
         "sablony=#{dopts[:templates].size}"
    puts "  bool povinne pole vynechane : #{ok(dopts[:custom_fields].none? do |c|
      c[:field].field_format == 'bool'
    end)}"

    dschema = RedmineAiAssistant::IssueDraft.schema(dopts)
    unknown = RedmineAiAssistant::IssueDraft::UNKNOWN
    puts "  schema: povinne kluce       : #{ok((%w[subject description tracker priority] -
                                               dschema[:required]).empty?)}"
    puts "  schema: enum zacina UNKNOWN : #{ok(dschema[:properties]['tracker'][:enum].first == unknown)}"
    # Gemini prazdny string v enum ODMIETNE ("enum[0]: cannot be empty").
    puts "  schema: enum bez prazdneho  : #{ok(dschema[:properties]['tracker'][:enum].none? do |v|
      v.to_s.empty?
    end)}"

    good = { 'subject' => 'Guest name too long', 'description' => 'x',
             'tracker' => dopts[:trackers].first.name,
             'priority' => dopts[:priorities].first.name }
    good['category'] = dopts[:categories].first.name if dopts[:categories].any?
    d1 = RedmineAiAssistant::IssueDraft.resolve(good, dopts)
    puts "  validna odpoved -> id       : #{ok(d1[:tracker_id] == dopts[:trackers].first.id &&
                                               d1[:priority_id] == dopts[:priorities].first.id)}"

    bad = { 'subject' => 'x', 'description' => 'y',
            'tracker' => 'Neexistujici tracker', 'priority' => 'Neexistujici priorita',
            'category' => 'CIZI KATEGORIE',
            'similar_issues' => [{ 'id' => 999_999_999, 'reason' => 'vymyslene' }] }
    if dopts[:custom_fields].any?
      cf_field = dopts[:custom_fields].first[:field]
      bad[RedmineAiAssistant::IssueDraft.cf_key(cf_field)] = 'Nikdo Neexistujici'
    end
    d2 = RedmineAiAssistant::IssueDraft.resolve(bad, dopts)
    puts "  cizi tracker zahodeny       : #{ok(d2[:tracker_id].nil?)}"
    puts "  cizi kategoria zahodena     : #{ok(d2[:category_id].nil?)}"
    puts "  cizi priorita zahodena      : #{ok(d2[:priority_id].nil?)}"
    puts "  cizi PM zahodeny            : #{ok(d2[:custom_field_values].blank?)}"
    puts "  nenabidnuta duplicita away  : #{ok(d2[:similar_issues].blank?)}"

    # Hladanie duplicit ide podla ANGLICKYCH klucovych slov od modelu — nazvy
    # uloh su anglicke, ale zadanie pise kazdy vo svojom jazyku. Kontroluje sa,
    # ze preklad ma prednost, ze sa cisti, a ze pri jeho absencii sa spadne
    # na originalne zadanie (slabsie hladanie je lepsie nez ziadne).
    cz = { :subject => 'nejde ulozit rezervaci kdyz ma host prilis dlouhe jmeno' }
    tok_orig = RedmineAiAssistant::IssueDraft.send(:search_tokens, cz, nil)
    tok_tr   = RedmineAiAssistant::IssueDraft.send(:search_tokens, cz,
                                                   ['reservation', 'guest', 'name'])
    puts "  bez prekladu = original     : #{ok(tok_orig.include?('rezervaci'))}"
    puts "  s prekladom = anglicke      : #{ok(tok_tr == %w[reservation guest name])}"
    puts "  prazdny preklad -> fallback : #{ok(
      RedmineAiAssistant::IssueDraft.send(:search_tokens, cz, []) == tok_orig
    )}"
    # Model vracia obcas frazu namiesto slova a slova kratsie nez 4 znaky robia
    # v LIKE hladani sum, preto sa odpoved cisti.
    puts "  fraza -> jednotlive slova   : #{ok(
      RedmineAiAssistant::IssueDraft.send(:normalize_keywords, ['guest name too long']) ==
        %w[guest name long]
    )}"
    puts "  kratke slova zahodene       : #{ok(
      RedmineAiAssistant::IssueDraft.send(:normalize_keywords, %w[bug app rate]) == %w[rate]
    )}"
    puts "  strop klucovych slov        : #{ok(
      RedmineAiAssistant::IssueDraft.send(:normalize_keywords,
        (1..20).map { |i| "word#{i}" }).size == RedmineAiAssistant::IssueDraft::MAX_SEARCH_KEYWORDS
    )}"
    puts "  schema klucovych slov       : #{ok(
      RedmineAiAssistant::IssueDraft::KEYWORDS_SCHEMA[:required] == ['keywords']
    )}"

    d3 = RedmineAiAssistant::IssueDraft.resolve(
      { 'subject' => 'x', 'description' => 'y', 'tracker' => unknown, 'priority' => unknown }, dopts
    )
    puts "  __UNKNOWN__ = prazdne pole  : #{ok(d3[:tracker_id].nil? && d3[:priority_id].nil?)}"

    # Model smie navrhnut iny projekt — ale len taky, kam uzivatel smie zakladat.
    puts "  projektov v ponuke          : #{dopts[:projects].size}"
    puts "  vsetky s pravom add_issues  : #{ok(dopts[:projects].all? do |p|
      User.current.allowed_to?(:add_issues, p)
    end)}"
    other = dopts[:projects].detect { |p| p.id != draft_project.id }
    if other
      dswitch = RedmineAiAssistant::IssueDraft.resolve(
        { 'subject' => 'x', 'description' => 'y', 'project' => other.name }, dopts
      )
      puts "  navrh ineho projektu prijaty: #{ok(dswitch[:project_id] == other.id)}"
    end
    dstay = RedmineAiAssistant::IssueDraft.resolve(
      { 'subject' => 'x', 'description' => 'y', 'project' => 'Neexistujici projekt' }, dopts
    )
    puts "  cizi projekt -> zostava tento: #{ok(dstay[:project_id] == draft_project.id)}"

    if RedmineAiAssistant.usable?
      Setting.plugin_redmine_ai_assistant =
        Setting.plugin_redmine_ai_assistant.to_h.merge('draft_enabled' => '1')
      dhtml = ApplicationController.render(
        partial: 'ai_assistant/new_issue_button',
        locals: { issue: Issue.new(project: draft_project), project: draft_project }
      )
      puts "  partial: tlacidlo draft     : #{ok(dhtml.include?('data-raa="draft"'))}"
      puts "  partial: zacina disabled    : #{ok(dhtml.include?('disabled'))}"
      # Na existujucej ulohe (editacia) sa tlacidlo renderovat NESMIE — `issues/_form`
      # je ten isty partial pre zakladanie aj pre upravu.
      if issue
        ehtml = ApplicationController.render(
          partial: 'ai_assistant/new_issue_button',
          locals: { issue: issue, project: issue.project }
        )
        puts "  partial: na editacii nie    : #{ok(!ehtml.include?('data-raa="draft"'))}"
      end
    else
      puts '  (plugin nie je usable — render partialu preskoceny)'
    end
  end
rescue StandardError => e
  puts "  !! SPADLO: #{e.class}: #{e.message}"
  puts "     #{e.backtrace.first(5).join("\n     ")}"
ensure
  Setting.plugin_redmine_ai_assistant = original
    # ---------------------------------------------------------------------------
  puts "\n[13] Rezim planu — schema, whitelist, prava"
  # Sekcia [11] pusta skutocne HTTP requesty a necha po sebe User.current
  # prestaveny (typicky Anonymous) — bez tohto by allowed_to? falosne padalo.
  User.current = user

  popts = RedmineAiAssistant::IssueDraft.options(draft_project, { :description => 'test' })
  puts "  options ma subtasks_allowed : #{ok(popts.key?(:subtasks_allowed))}"
  puts "  zhoduje sa s pravom         : #{ok(popts[:subtasks_allowed] ==
        User.current.allowed_to?(:manage_subtasks, draft_project))}"

  psch = RedmineAiAssistant::IssueDraft.plan_schema(popts, 6)
  pitems = psch[:properties]['issues']
  puts "  issues je ARRAY of OBJECT   : #{ok(pitems[:type] == 'ARRAY' &&
        pitems[:items][:type] == 'OBJECT')}"
  puts "  use_parent BOOLEAN + required: #{ok(psch[:properties]['use_parent'][:type] == 'BOOLEAN' &&
        psch[:required].include?('use_parent'))}"
  puts "  enum v items zacina UNKNOWN : #{ok(
        pitems[:items][:properties]['tracker'][:enum].first == unknown)}"
  puts "  polozka NEMA vlastny project: #{ok(!pitems[:items][:properties].key?('project'))}"
  # Enum sa NESMIE duplikovat per polozku — to je cely dovod, preco ide plan
  # jednym volanim namiesto N volani.
  tname = Regexp.escape(dopts[:trackers].first.name)
  puts "  enum trackerov v schema 1x  : #{ok(psch.to_json.scan(/#{tname}/).size <= 2)}"

  good_plan = { 'plan_summary' => 'Rozdelene na tri kroky.', 'use_parent' => true,
                'project' => draft_project.name,
                'issues' => (1..3).map do |i|
                  { 'subject' => "Step #{i}", 'description' => 'x',
                    'tracker' => dopts[:trackers].first.name,
                    'priority' => dopts[:priorities].first.name }
                end }
  pl1 = RedmineAiAssistant::IssueDraft.resolve_plan(good_plan, popts, 6)
  puts "  tri polozky, prva je parent : #{ok(pl1[:issues].size == 3 && pl1[:use_parent])}"
  puts "  project_id v kazdej polozke : #{ok(pl1[:issues].all? do |i|
        i[:project_id] == draft_project.id
      end)}"

  # NAJDOLEZITEJSIE: hodnota, ktoru sme modelu NEnabidli, sa nesmie dostat do
  # formulara — a to v KAZDEJ polozke, nie len v prvej.
  bad_plan = good_plan.merge('issues' => good_plan['issues'].map do |i|
    i.merge('tracker' => 'Neexistujici', 'category' => 'CIZI KATEGORIE')
  end)
  pl2 = RedmineAiAssistant::IssueDraft.resolve_plan(bad_plan, popts, 6)
  puts "  cizi tracker zahodeny vsade : #{ok(pl2[:issues].all? { |i| i[:tracker_id].nil? })}"
  puts "  cizi kategoria zahodena vsade: #{ok(pl2[:issues].all? { |i| i[:category_id].nil? })}"

  many_plan = good_plan.merge('issues' => (1..30).map do |i|
    { 'subject' => "S#{i}", 'description' => 'x' }
  end)
  puts "  strop podla nastavenia      : #{ok(
        RedmineAiAssistant::IssueDraft.resolve_plan(many_plan, popts, 6)[:issues].size == 6)}"
  puts "  strop kodu nad nastavenim   : #{ok(
        RedmineAiAssistant::IssueDraft.resolve_plan(many_plan, popts, 999)[:issues].size ==
        RedmineAiAssistant::IssueDraft::MAX_PLAN_ITEMS)}"

  noperm = popts.merge(:subtasks_allowed => false)
  puts "  bez prava use_parent=false  : #{ok(
        RedmineAiAssistant::IssueDraft.resolve_plan(good_plan, noperm, 6)[:use_parent] == false)}"
  puts "  jedna uloha -> bez parenta  : #{ok(
        RedmineAiAssistant::IssueDraft.resolve_plan(
          good_plan.merge('issues' => [good_plan['issues'].first]), popts, 6)[:use_parent] == false)}"
  puts "  nezmyselny vstup neplati    : #{ok(
        RedmineAiAssistant::IssueDraft.resolve_plan(nil, popts, 6)[:issues].empty?)}"

  # Cache prefix MUSI oddelovat formaty payloadu: with_ai_guard renderuje to, co
  # najde v cache, takze pri zdielanom prefixe by klient dostal draft tam, kde
  # ziada plan.
  pctrl = AiAssistantController.new
  puts "  cache: plan != draft kluc   : #{ok(
        pctrl.send(:cache_key, 'draft', [1], 'S', 'U') !=
        pctrl.send(:cache_key, 'plan', [1], 'S', 'U'))}"

  pprompt = RedmineAiAssistant::ContextBuilder.issue_plan_prompt(
    draft_project,
    { :description => 'nejde ulozit rezervaci',
      :messages => [{ 'role' => 'user', 'text' => 'najprv validacia' },
                    { 'role' => 'ai', 'text' => 'navrhujem tri kroky' }] }, popts, 6)
  puts "  prompt: strop poctu uloh    : #{ok(pprompt.include?('Maximálně 6'))}"
  puts "  prompt: obe strany konverzacie: #{ok(pprompt.include?('- Uživatel: najprv validacia') &&
        pprompt.include?('- Ty: navrhujem tri kroky'))}"
  puts "  prompt: bez prava Hierarchie: #{ok(
        RedmineAiAssistant::ContextBuilder.issue_plan_prompt(
          draft_project, { :description => 'x' }, noperm, 6).include?('# Hierarchie'))}"
  puts "  prompt: s pravom bez sekcie : #{ok(!pprompt.include?('# Hierarchie'))}"
  puts "  prompt: ziadna privatna     : #{ok(Issue.where(:project_id => draft_project.id,
        :is_private => true).none? { |i| pprompt.include?(i.subject.to_s) })}"

  # Projekt vybera SAMOSTATNE volanie, ktore nevidi kategorie ani sablony —
  # s nimi v kontexte si model ulohu prisposoboval TOMU projektu namiesto toho,
  # aby vybral podla obsahu.
  pprojects = RedmineAiAssistant::IssueDraft.allowed_projects
  psch2 = RedmineAiAssistant::IssueDraft.project_schema(pprojects)
  puts "  schema vyberu: project+reason: #{ok(psch2[:required].sort == %w[project reason].sort)}"
  puts "  schema vyberu: enum projektov: #{ok(
        psch2[:properties]['project'][:enum].to_a.include?(unknown))}"
  ppick = RedmineAiAssistant::ContextBuilder.project_pick_prompt(
    { :description => 'test zadanie' }, pprojects)
  puts "  prompt vyberu: bez kategorii : #{ok(!ppick.include?('Kategorie projektu'))}"
  puts "  prompt vyberu: bez sablon    : #{ok(!ppick.include?('ablona'))}"
  puts "  prompt vyberu: ma projekty   : #{ok(ppick.include?(pprojects.first.name))}"

  # Prutik v hlavicke je viazany na vlastny prepinac aj na prihlasenie.
  puts "  menu: prutik je v account   : #{ok(
        Redmine::MenuManager.items(:account_menu).children.any? do |i|
          i.name == :ai_issue_creator
        end)}"

  # Klavesova skratka Ctrl/Cmd+Shift+X na okno planu. Kontroluje sa tu preto, ze
  # tri veci musia sedet naraz: text v troch jazykoch, jeho cesta do js_config
  # a ochrana proti AltGr.
  puts "  skratka: kluc vo vsetkych 3 : #{ok(
        %w[cs sk en].all? do |lang|
          I18n.with_locale(lang) { I18n.t('ai_assistant.plan_shortcut_hint', :keys => 'X') }
             .to_s.include?('X')
        rescue StandardError
          false
        end)}"
  hooks_src = File.read(File.expand_path('../lib/redmine_ai_assistant/hooks.rb', __dir__))
  puts "  skratka: ide do js_config   : #{ok(hooks_src.include?('shortcutHint'))}"
  # AltGr je na Windows ctrl+alt, takze bez tejto podmienky by okno vyskakovalo
  # pri pisani @ alebo € na CZ/SK/PL/HU klavesnici.
  js_shortcut = File.read(File.expand_path('../assets/javascripts/ai_assistant.js', __dir__))
  puts "  skratka: chrani AltGr       : #{ok(
        js_shortcut.include?('|| event.altKey) { return false; }'))}"

  # --- 14. bezpecnostne poistky (audit 21. 8. 2026) ------------------------
  #
  # Kazda kontrola v tejto sekcii zodpoveda NAMERANEJ vade, nie domnienke.

  puts ''
  puts '[14] Bezpecnostne poistky'

  # (a) Kazdy prepinac riadi VYHRADNE svoju funkciu. Predtym sa rezim planu
  #     pytal cez available_for_draft?, takze bez draft_enabled nebezal vobec.
  sec_project = Project.allowed_to(user, :add_issues).active.sorted.first
  if sec_project
    sec_base = Setting.plugin_redmine_ai_assistant.to_h
    matrix = [%w[1 1], %w[1 0], %w[0 1], %w[0 0]].map do |plan_on, draft_on|
      s = sec_base.dup
      s['enabled'] = '1'
      s['plan_enabled']  = plan_on
      s['draft_enabled'] = draft_on
      Setting.plugin_redmine_ai_assistant = s
      Setting.clear_cache if Setting.respond_to?(:clear_cache)
      [RedmineAiAssistant.available_for_plan?(sec_project, user),
       RedmineAiAssistant.available_for_draft?(sec_project, user)]
    end
    Setting.plugin_redmine_ai_assistant = sec_base
    Setting.clear_cache if Setting.respond_to?(:clear_cache)
    # Kluc su stredne dve dvojice: len plan => [true, false], len draft => [false, true].
    puts "  prepinace: plan bez draftu  : #{ok(matrix[1] == [true, false])}"
    puts "  prepinace: draft bez planu  : #{ok(matrix[2] == [false, true])}"
    puts "  prepinace: oba vypnute      : #{ok(matrix[3] == [false, false])}"
  else
    puts '  prepinace: PRESKOCENE (uzivatel nesmie nikde zakladat ulohy)'
  end

  # (b) CSRF sa musi vynutit aj na .json rutach. Redmine kontrolu preskakuje pre
  #     api_request?, ktore sa riadi VYHRADNE priponou v adrese — POST na
  #     /ai_assistant/plan_issues.json tak presiel bez tokenu a spustil
  #     platene volania. NAMERANE 21. 8. 2026.
  puts "  CSRF: .json nie je API      : #{ok(!AiAssistantController.new.send(:api_request?))}"

  # (c) Hodinovy limit sa uctuje pri KAZDOM platenom volani, nie raz za request.
  #     Kontrola je v ask_model; with_ai_guard ju uz nerobi, lebo pomocne volania
  #     (vyber projektu, klucove slova) bezia jeste pred zostavenim cache kluca.
  #     Predtym: HTTP 429, ale dve volania uz boli zaplatene.
  ctrl_src = File.read(File.expand_path('../app/controllers/ai_assistant_controller.rb', __dir__))
  puts "  limit: uctuje ask_model     : #{ok(
        ctrl_src[/def ask_model.*?\n  end/m].to_s.include?('charge_quota!'))}"
  puts "  limit: with_ai_guard neuctuje: #{ok(
        !ctrl_src[/def with_ai_guard.*?\n  end/m].to_s.include?('rate_limit'))}"
  puts "  limit: uctuju aj pomocne    : #{ok(ctrl_src.scan(/ask_model\(/).size >= 4)}"
  # Vycerpany limit sa v pomocnych krokoch NESMIE prehltnut spolu s ostatnymi
  # chybami — inak by sa 429 poslalo az po zaplateni.
  puts "  limit: pomocne ho prepustaju: #{ok(
        ctrl_src.scan(/rescue QuotaExceeded\n    raise/).size == 2)}"
  puts "  limit: samotne uctovanie    : #{ok(
        ctrl_src.include?('raise QuotaExceeded unless RedmineAiAssistant.consume_rate_limit!'))}"

  # (d) Fronta sprievodcu sa odistuje ODOSLANIM formulara, nie adresou. Bez toho
  #     stacilo z formulara odbocit na existujucu ulohu a fronta ju zapocitala
  #     ako zalozenu — jej cislo sa stalo nadradenou ulohou a podulohy sa
  #     naviazali na cudziu vec. Klientska strana ma na to testy v plan_test.js.
  js_src = File.read(File.expand_path('../assets/javascripts/ai_assistant.js', __dir__))
  puts "  fronta: ceka na submit      : #{ok(js_src.include?('q.submitted && q.awaiting !== null'))}"
  puts "  fronta: submit ju odisti    : #{ok(js_src.include?('fresh.submitted = true'))}"
  puts "  fronta: vrateny formular zhasne: #{ok(
        js_src.include?('} else if (!issueId && q.submitted) {'))}"

  puts "\n  (nastavenia pluginu vratene do povodneho stavu)"
end

puts "\n" + '=' * 78
