# frozen_string_literal: true

# Self-test kódového kontextu (GitLab → prompt).
#
# Spustenie — POZOR na `--user redmine`:
#   docker compose exec -T --user redmine -e SECRET_KEY_BASE=<key> redmine \
#     bin/rails runner -e production plugins/redmine_ai_assistant/extra/code_selftest.rb
#
# Väčšina kontrol je OFFLINE — netreba GitLab ani token. Testujú presne to, čo sa
# nesmie ticho pokaziť: že sa token neposiela na cudzí host, že súbory s
# tajomstvami do promptu nejdú a že sa hodnoty podobné heslám prepisujú.
#
# Sekcia [7] je živá a spustí sa LEN vtedy, keď je token naozaj nastavený.
# Nastavenia pluginu sa na konci vracajú do pôvodného stavu.

OK = []
BAD = []

def check(label, got, want)
  ok = got == want
  (ok ? OK : BAD) << label
  puts format('  %-56s %s', label, ok ? 'OK' : "!! ZLE (#{got.inspect}, cakalo sa #{want.inspect})")
end

CC = RedmineAiAssistant::CodeContext
HOST = 'gitlab.previo.info'

puts '=' * 78
puts '  ai_assistant — kod z GitLabu'
puts '=' * 78

original = Setting.plugin_redmine_ai_assistant

begin
  # --- 1. odkaz na merge request -------------------------------------------
  puts ''
  puts '[1] Rozpoznanie odkazu na MR'
  mr = CC.parse_link("https://#{HOST}/previo/previo2/-/merge_requests/5270", HOST)
  check('projekt sa precita spravne', mr && mr[:project], 'previo/previo2')
  check('iid sa precita spravne', mr && mr[:ref], '5270')
  check('druh je merge_requests', mr && mr[:kind], 'merge_requests')

  commit = CC.parse_link("https://#{HOST}/previo/previo/-/commit/a46f37993a8ae67e9a49f400a6cc22a714572e71", HOST)
  check('commit URL sa tiez rozpozna', commit && commit[:kind], 'commit')

  # Toto je bezpecnostna kontrola, nie kozmetika: pole s odkazom vyplna clovek.
  evil = CC.parse_link('https://gitlab.example.com/x/y/-/merge_requests/1', HOST)
  check('CUDZI host sa odmietne', evil, nil)
  check('odkaz na iny modul GitLabu sa odmietne',
        CC.parse_link("https://#{HOST}/previo/previo2/-/issues/12", HOST), nil)
  check('nezmysel sa odmietne', CC.parse_link('nieco uplne ine', HOST), nil)
  check('prazdna hodnota sa odmietne', CC.parse_link('', HOST), nil)
  check('bez znameho hostu sa odmietne vsetko',
        CC.parse_link("https://#{HOST}/a/b/-/merge_requests/1", nil), nil)

  # --- 2. cesty, ktore do promptu nesmu ------------------------------------
  puts ''
  puts '[2] Subory s tajomstvami'
  [
    'config/secrets/prod/prod.RABBITMQ_RESERVATION_URL.b85069.php',
    '.env',
    'app/.env.local',
    'config/secrets.yml',
    'deploy/id_rsa',
    'certs/server.pem',
    'ssl/private.key',
    'auth.json',
    'src/CredentialStore.php'
  ].each { |p| check("blokuje #{p}", CC.deny_path?(p), true) }

  check('prazdna cesta je tiez blokovana', CC.deny_path?(''), true)

  puts ''
  puts '[3] Bezny kod prejde, balast nie'
  ['src/app/Reservation.php', 'assets/js/booking.ts', 'docs/reservations.md'].each do |p|
    check("prejde #{p}", CC.skip_path?(p), false)
  end
  ['package-lock.json', 'node_modules/x/index.js', 'dist/app.min.js',
   'public/logo.png', 'vendor/lib/a.php'].each do |p|
    check("vynecha #{p}", CC.skip_path?(p), true)
  end

  # --- 4. prepis hodnot, ktore vyzeraju ako tajomstvo -----------------------
  puts ''
  puts '[4] Prepis tajomstiev v texte'
  red = CC.redact('+ $apiKey = "sk-live-0123456789abcdef";')
  check('hodnota api kluca zmizne', red.include?('0123456789abcdef'), false)
  check('ale nazov premennej zostane', red.include?('apiKey'), true)

  check('password sa prepise',
        CC.redact('password: SuperTajne123').include?('SuperTajne123'), false)
  check('token sa prepise',
        CC.redact('AUTH_TOKEN=abcdefgh12345678').include?('abcdefgh12345678'), false)
  check('bezny kod sa nemeni',
        CC.redact('return $reservation->getTotalPrice();'),
        'return $reservation->getTotalPrice();')
  check('nil nespadne', CC.redact(nil), '')

  # --- 5. rozpocet diffu ----------------------------------------------------
  puts ''
  puts '[5] Rozpocet diffu'
  changes = [
    { 'new_path' => 'src/a.php', 'diff' => 'a' * 5_000 },
    { 'new_path' => 'src/b.php', 'diff' => 'b' * 5_000 },
    { 'new_path' => 'config/secrets/prod.php', 'diff' => 'TAJNE' * 100 },
    { 'new_path' => 'package-lock.json', 'diff' => 'c' * 5_000 },
    { 'new_path' => 'certs/key.pem', 'diff' => "-----BEGIN RSA PRIVATE KEY-----\nMIIE" }
  ]
  out = CC.send(:diff_section, changes, 'code_diff_limit' => '8000').join("\n")
  check('celkovy strop sa dodrzal', out.length <= 8_000 + 600, true)
  check('subor s tajomstvom v diffe NIE JE', out.include?('TAJNE'), false)
  check('a je uvedeny ako vynechany', out.include?('config/secrets/prod.php'), true)
  check('lock subor sa vynechal', out.include?('c' * 100), false)
  check('privatny kluc sa vynechal', out.include?('BEGIN RSA PRIVATE KEY'), false)
  check('bezny subor sa dostal dnu', out.include?('src/a.php'), true)

  per_file = CC.send(:diff_section, [{ 'new_path' => 'src/big.php', 'diff' => 'x' * 100_000 }],
                     'code_diff_limit' => '8000').join("\n")
  check('jeden subor nezhltne cely rozpocet', per_file.count('x') <= 2_100, true)

  # --- 6. vypinac a chybajuca konfiguracia ----------------------------------
  puts ''
  puts '[6] Vypinac a degradacia'
  issue = Issue.order(:id => :desc).first
  check('vypnute => ziadny kod',
        CC.issue_section(issue, 'code_context_enabled' => '0'), [])
  check('zapnute bez tokenu => ziadny kod a ziadny pad',
        CC.issue_section(issue, 'code_context_enabled' => '1', 'gitlab_url' => "https://#{HOST}"), [])
  check('draft: vypnute => ziadny kod',
        CC.draft_section(Project.active.first, %w[reservation], 'code_context_enabled' => '0'), [])

  # Nedostupny GitLab nesmie zhodit navrh odpovede.
  Setting.plugin_redmine_ai_assistant = original.to_h.merge(
    'gitlab_token' => RedmineAiAssistant::Credentials.encrypt('dummy-token-selftest')
  )
  dead = { 'code_context_enabled' => '1', 'gitlab_url' => 'https://gitlab.invalid.localhost',
           'code_diff_limit' => '8000' }
  check('nedostupny GitLab => prazdno, nie vynimka', CC.issue_section(issue, dead), [])

  # --- 7. lokalizacia -------------------------------------------------------
  puts ''
  puts '[7] Lokalizacia'
  %w[en sk cs].each do |lang|
    missing = %w[legend_code setting_code_enabled setting_gitlab_url setting_gitlab_token
                 setting_code_diff_limit setting_code_search].reject do |key|
      ::I18n.t("ai_assistant.#{key}", :locale => lang, :default => '').present?
    end
    check("#{lang}: vsetky texty su prelozene", missing, [])
  end

  html = ApplicationController.render(:partial => 'settings/ai_assistant',
                                      :locals => { :settings => RedmineAiAssistant.settings })
  check('token NIE JE v HTML nastaveni', html.include?('dummy-token-selftest'), false)
  check('pole na token je bez value=',
        html.match?(/id="ai_assistant_gitlab_token"[^>]*value=/), false)

  # --- 8. ulozenie tokenu ---------------------------------------------------
  puts ''
  puts '[8] Ulozenie tokenu'
  ks = RedmineAiAssistant::KeyStore
  params = { 'gitlab_token' => 'novy-token-1234' }
  ks.merge_into_params!(params)
  check('novy token sa ulozi sifrovane', params['gitlab_token'].include?('novy-token-1234'), false)
  check('a da sa desifrovat', RedmineAiAssistant::Credentials.decrypt(params['gitlab_token']),
        'novy-token-1234')
  check('hint su posledne 4 znaky', params['gitlab_token_hint'], '1234')

  kept = { 'gitlab_token' => '' }
  ks.merge_into_params!(kept)
  check('prazdne pole ulozeny token NEZMAZE',
        RedmineAiAssistant::Credentials.decrypt(kept['gitlab_token']), 'dummy-token-selftest')

  cleared = { 'gitlab_token' => '', 'gitlab_token_clear' => '1' }
  ks.merge_into_params!(cleared)
  check('zaskrtnute zmazanie token zmaze', cleared['gitlab_token'], '')

  only_gemini = { 'api_key' => '' }
  ks.merge_into_params!(only_gemini)
  check('formular bez pola na GitLab token ho nezmaze', only_gemini.key?('gitlab_token'), false)

  # --- 9. ziva skuska (len ak je token naozaj nastaveny) --------------------
  puts ''
  puts '[9] Ziva skuska proti GitLabu'
  Setting.plugin_redmine_ai_assistant = original
  real = RedmineAiAssistant.settings
  if RedmineAiAssistant::KeyStore.present?(RedmineAiAssistant::KeyStore::GITLAB_KEY)
    client = CC.client(real)
    begin
      version = client.send(:get, '/version')
      puts "  GitLab odpoveda, verzia: #{version['version']}"
      check('spojenie funguje', version['version'].present?, true)
    rescue RedmineAiAssistant::GitlabClient::Error => e
      check("spojenie funguje (#{e.message})", false, true)
    end
  else
    puts '  (preskocene — GitLab token nie je nastaveny)'
  end
ensure
  Setting.plugin_redmine_ai_assistant = original
  Rails.cache.clear
end

puts ''
puts '=' * 78
puts "  OK: #{OK.size}   CHYBA: #{BAD.size}"
puts '=' * 78
