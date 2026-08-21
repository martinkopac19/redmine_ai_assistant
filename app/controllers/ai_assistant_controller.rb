# frozen_string_literal: true

class AiAssistantController < ApplicationController
  before_action :require_login
  before_action :require_usable

  # Vyčerpaný hodinový limit. Vlastná výnimka, a nie návratová hodnota: platené
  # volania sú rozhodené po celej akcii (výber projektu, preklad kľúčových slov,
  # hlavné volanie) a kontrola musí byť u KAŽDÉHO z nich. Keď bola len jedna, na
  # začiatku `with_ai_guard`, dali sa dve platené volania spraviť ešte pred ňou —
  # klient dostal HTTP 429, ale zaplatilo sa.
  class QuotaExceeded < StandardError; end

  rescue_from QuotaExceeded, :with => :render_rate_limited

  # POZOR: `render_error` NEPREPISOVAŤ — Redmine core má vlastné
  # ApplicationController#render_error(arg) s jedným argumentom a používa ho
  # v obsluhe CSRF a chybových stránok. Prepísanie ho rozbije (500 namiesto 422).
  # Preto sa naša metóda volá render_json_error.

  # Pomocný preklad kľúčových slov nemá vlastný nastaviteľný prompt: nie je to
  # miesto, kde by admin niečo ladil, a schéma robí formát odpovede aj tak.
  KEYWORDS_SYSTEM_PROMPT = 'Jsi překladač klíčových slov pro hledání v Redmine. '                            'Odpovídáš výhradně JSON podle schématu.'

  # Strop, nie cena — platí sa za skutočne vygenerované tokeny. Je vyšší, než by
  # osem slov potřebovalo, pretože u modelov s uvažovaním sa limit delí medzi
  # uvažovanie a odpoveď a odrezaný JSON by preklad zhodil.
  KEYWORDS_MAX_TOKENS = 4_096

  # Rovnaký dôvod ako u kľúčových slov: strop, nie cena. Odpoveď je jeden názov
  # a jedna veta, ale uvažovanie sa do limitu počíta.
  PROJECT_PICK_SYSTEM_PROMPT = 'Jsi zkušený projektový manažer v Previo.cz. ' \
                               'Zařazuješ zadání do správného projektu v Redmine. ' \
                               'Odpovídáš výhradně JSON podle schématu.'
  PROJECT_PICK_MAX_TOKENS = 4_096

  def suggest
    issue = find_available_issue
    return if issue.nil?

    settings = RedmineAiAssistant.settings
    deliver('suggest', issue,
            RedmineAiAssistant.system_prompt_for(User.current),
            RedmineAiAssistant::ContextBuilder.suggestion_prompt(issue, settings))
  end

  # Zhrnutie celej úlohy (popis + verejné komentáre). Len sa zobrazí v overlay
  # okne — nikam sa nevkladá a do Redmine sa nič nezapisuje.
  def summary
    issue = find_available_issue
    return if issue.nil?

    settings = RedmineAiAssistant.settings
    deliver('summary', issue,
            RedmineAiAssistant.system_prompt_for(User.current, 'summary_system_prompt'),
            RedmineAiAssistant::ContextBuilder.summary_prompt(issue, settings))
  end

  # Predvyplnenie novej úlohy z krátkeho zadania. Nič sa neukladá — vracia sa
  # návrh, ktorý si klient vloží do formulára. Uloženie robí jadrový
  # IssuesController#create, takže práva a validácie zostávajú na jadre.
  def draft_issue
    project = Project.find_by(:id => params[:project_id])
    unless RedmineAiAssistant.available_for_draft?(project)
      return render_json_error(:'ai_assistant.error_unavailable', :forbidden)
    end

    input = { :subject => params[:subject].to_s, :description => params[:description].to_s,
              :history => history_param }
    if [input[:subject], input[:description]].all? { |v| v.strip.empty? }
      return render_json_error(:'ai_assistant.error_draft_empty', :unprocessable_entity)
    end

    settings      = RedmineAiAssistant.settings
    keywords      = translated_search_keywords(input, settings)
    opts          = RedmineAiAssistant::IssueDraft.options(project, input, settings, keywords)
    system_prompt = RedmineAiAssistant.system_prompt_for(User.current, 'draft_system_prompt')
    user_prompt   = RedmineAiAssistant::ContextBuilder.issue_draft_prompt(project, input, opts)

    with_ai_guard(cache_key('draft', [project.id], system_prompt, user_prompt)) do
      draft, chosen = draft_with_project_switch(project, input, opts, system_prompt, settings,
                                                keywords)
      { :draft   => draft,
        :project => { :id => chosen.id, :name => chosen.name,
                      :changed => chosen.id != project.id } }
    end
  end

  # Režim plánu: z voľného zadania návrh jednej alebo viacerých úloh, prípadne
  # s hierarchiou. Nič sa neukladá — vracia sa plán, ktorý si klient postupne
  # predvyplní do jadrového formulára a Create klikne pri každej úlohe človek.
  def plan_issues
    # Projekt od klienta je nepovinný: v režime plánu ho vyberá AI a select
    # v okne slúži len na ručnú opravu po návrhu.
    project = Project.find_by(:id => params[:project_id]) ||
              RedmineAiAssistant::IssueDraft.allowed_projects.first
    # Vlastný prepínač, nie ten od predvyplnenia formulára: režim plánu sa má dať
    # nasadiť aj vypnúť bez dotyku už bežiacich funkcií, a `available_for_draft?`
    # vyžaduje `draft_enabled` — tým boli oba prepínače de facto zviazané.
    unless RedmineAiAssistant.available_for_plan?(project)
      return render_json_error(:'ai_assistant.error_unavailable', :forbidden)
    end

    input = { :description => params[:input].to_s, :messages => messages_param }
    if input[:description].strip.empty?
      return render_json_error(:'ai_assistant.error_plan_empty', :unprocessable_entity)
    end

    settings  = RedmineAiAssistant.settings
    max_items = settings['plan_max_items'].to_i

    # Projekt vyberá AI podľa obsahu zadania — v režime plánu človek nikde
    # „nestojí" a vyberať projekt dopredu by znamenalo hádať. Keď si ho ale
    # v okne prepol ručne, jeho voľba platí a nič sa nedopytuje.
    unless %w[1 true].include?(params[:lock_project].to_s)
      picked = pick_project(input)
      project = picked[:project] if picked[:project]
      @plan_project_reason = picked[:reason]
    end
    # Kľúčové slová na hľadanie duplicít sa prekladajú z toho istého dôvodu ako
    # pri jednej úlohe — zadanie píše každý vo svojom jazyku, názvy úloh sú anglicky.
    keywords  = translated_search_keywords({ :description => input[:description] }, settings)
    opts      = plan_options(project, input, settings, keywords, params[:lock_project])
    system_prompt = RedmineAiAssistant.system_prompt_for(User.current, 'plan_system_prompt')
    user_prompt   = RedmineAiAssistant::ContextBuilder.issue_plan_prompt(project, input, opts,
                                                                        max_items)

    # Cache prefix je 'plan', nie 'draft': `with_ai_guard` renderuje čokoľvek, čo
    # v cache nájde, a payload plánu má iný tvar než payload jednej úlohy.
    with_ai_guard(cache_key('plan', [project.id], system_prompt, user_prompt)) do
      plan, chosen = plan_with_project_switch(project, input, opts, system_prompt, settings,
                                             keywords, max_items)
      { :plan    => plan,
        :project => { :id => chosen.id, :name => chosen.name,
                      :reason => @plan_project_reason,
                      # Klient tým nič nehlási — projekt vybrala AI, takže nie je
                      # čo označovať za „zmenu". Ponechané pre zhodu tvaru payloadu.
                      :changed => false } }
    end
  end

  # Číselník projektov pre okno režimu plánu: kam smie užívateľ zakladať úlohy
  # a v ktorých z nich smie spravovať podúlohy.
  #
  # Prečo samostatná akcia a nie `js_config`: ten sa vykresľuje v layoute na
  # KAŽDEJ stránke a nesmie robiť SQL dotazy. Sem sa ide až pri prvom otvorení
  # okna. Žiadne volanie AI, teda ani spotrebovaný hodinový limit.
  def plan_context
    unless RedmineAiAssistant.plan_usable?
      return render_json_error(:'ai_assistant.error_unavailable', :forbidden)
    end

    projects = RedmineAiAssistant::IssueDraft.allowed_projects
    # Jedno `pluck` namiesto `allowed_to?` v cykle — pri 63 projektoch by to
    # bolo 63 dotazov len na vykreslenie jedného selectu.
    with_subtasks = Project.allowed_to(User.current, :manage_subtasks).pluck(:id).to_set

    render :json => {
      :projects => projects.map { |p| { :id => p.id, :name => p.name,
                                        :subtasks => with_subtasks.include?(p.id) } },
      :current  => params[:project_id].presence&.to_i
    }
  end

  private

  # Model smie navrhnúť iný projekt, než v ktorom užívateľ stojí — bez toho sa
  # snažil napr. CRM úlohu natlačiť do Channel Managera a vymyslel k tomu
  # nezmyselnú kategóriu.
  #
  # Kategórie, PM ani šablóny ostatných projektov v prompte NIE SÚ (bolo by to
  # 464 kategórií naraz), takže po zmene projektu sa model zavolá ešte raz, už
  # s kontextom toho správneho. Druhý priechod je len jeden — prípadnú ďalšiu
  # zmenu projektu ignorujeme, aby sa to nemohlo zacykliť.
  def draft_with_project_switch(project, input, opts, system_prompt, settings, keywords = nil)
    draft  = RedmineAiAssistant::IssueDraft.resolve(
      ask_for_draft(system_prompt, project, input, opts, settings), opts
    )
    chosen = Project.find_by(:id => draft[:project_id])

    return [draft, project] if chosen.nil? || chosen.id == project.id
    # Právo sa overuje znova: `allowed_projects` ho síce filtruje, ale na tomto
    # rozhodnutí stojí, kam úloha pôjde.
    return [draft, project] unless User.current.allowed_to?(:add_issues, chosen)

    # Kľúčové slová sa neprekladajú znova — zadanie je to isté, mení sa len projekt.
    opts2 = RedmineAiAssistant::IssueDraft.options(chosen, input, settings, keywords)
    draft2 = RedmineAiAssistant::IssueDraft.resolve(
      ask_for_draft(system_prompt, chosen, input, opts2, settings), opts2
    )
    [draft2.merge(:project_id => chosen.id), chosen]
  end

  # Zadanie v ľubovoľnom jazyku → anglické kľúčové slová na hľadanie duplicít.
  #
  # Musí to byť samostatné volanie PRED hlavným návrhom: kandidáti na duplicitu
  # patria do promptu hlavného volania, takže sa nedajú získať z jeho odpovede.
  # Prompt aj odpoveď sú malé a cachujú sa zvlášť, aby opakovaný klik na to isté
  # zadanie neplatil preklad druhý raz.
  #
  # Zlyhanie sa ZÁMERNE nepreposiela von — keď preklad nevyjde, hľadá sa podľa
  # originálneho zadania a návrh úlohy vznikne normálne. Spadnúť na pomocnom
  # kroku, ktorý má hlavnú funkciu iba zlepšiť, by bola zlá výmena.
  def translated_search_keywords(input, settings)
    return nil unless settings['draft_translate_keywords'].to_s == '1'

    prompt = RedmineAiAssistant::ContextBuilder.search_keywords_prompt(input)
    key    = cache_key('draft_keywords', [], KEYWORDS_SYSTEM_PROMPT, prompt)
    cached = Rails.cache.read(key)
    return cached if cached.present?

    data  = ask_model(KEYWORDS_SYSTEM_PROMPT, prompt,
                      RedmineAiAssistant::IssueDraft::KEYWORDS_SCHEMA,
                      KEYWORDS_MAX_TOKENS)
    words = Array(data['keywords']).map(&:to_s)
    Rails.cache.write(key, words, :expires_in => 1.hour) if words.any?
    words
  # Vyčerpaný limit sa NEPREHLTÁ: je to odpoveď užívateľovi, nie zlyhanie
  # pomocného kroku, ktoré sa má obísť a pokračovať bez neho.
  rescue QuotaExceeded
    raise
  rescue StandardError => e
    Rails.logger.warn("[ai_assistant] preklad klucovych slov zlyhal: #{e.class}: #{e.message}")
    nil
  end

  # Výber projektu samostatným, malým volaním.
  #
  # Prečo nie v hlavnom volaní: keď model dostal zadanie spolu s kategóriami
  # a šablónami jedného projektu, prispôsoboval úlohu TOMU projektu namiesto toho,
  # aby vybral podľa obsahu. Tu nevidí nič okrem zoznamu projektov.
  #
  # Zlyhanie sa ZÁMERNE nepreposiela von — bez výberu sa použije projekt, ktorý
  # prišiel od klienta, a plán vznikne normálne.
  def pick_project(input)
    projects = RedmineAiAssistant::IssueDraft.allowed_projects
    return {} if projects.size < 2

    prompt = RedmineAiAssistant::ContextBuilder.project_pick_prompt(input, projects)
    key    = cache_key('plan_project', [], PROJECT_PICK_SYSTEM_PROMPT, prompt)
    cached = Rails.cache.read(key)
    return cached if cached.present?

    data  = ask_model(PROJECT_PICK_SYSTEM_PROMPT, prompt,
                      RedmineAiAssistant::IssueDraft.project_schema(projects),
                      PROJECT_PICK_MAX_TOKENS)
    name  = data['project'].to_s
    found = projects.detect { |p| p.name.to_s.strip.casecmp(name.strip).zero? }
    out   = { :project => found, :reason => data['reason'].to_s.strip.presence }
    Rails.cache.write(key, out, :expires_in => 1.hour) if found
    out
  rescue QuotaExceeded
    raise
  rescue StandardError => e
    Rails.logger.warn("[ai_assistant] vyber projektu zlyhal: #{e.class}: #{e.message}")
    {}
  end

  # Zamknutý projekt = whitelist s jedinou hodnotou. Nie je to zvláštna cesta
  # v kóde, je to ten istý mechanizmus ponuky, akým sa filtruje všetko ostatné —
  # a preto sa parametru od klienta dá dôverovať: smie whitelist len ZÚŽIŤ.
  def plan_options(project, input, settings, keywords, lock)
    opts = RedmineAiAssistant::IssueDraft.options(project, input, settings, keywords)
    opts[:projects] = [project] if %w[1 true].include?(lock.to_s)
    opts
  end

  # Druhý priechod pri zmene projektu — dôvod aj poistka proti zacykleniu sú
  # rovnaké ako pri `draft_with_project_switch`. Podstatný rozdiel: `use_parent`
  # sa vyhodnocuje proti ZVOLENÉMU projektu, takže právo :manage_subtasks sa overí
  # tam, kde úlohy naozaj vzniknú.
  def plan_with_project_switch(project, input, opts, system_prompt, settings, keywords, max_items)
    plan   = RedmineAiAssistant::IssueDraft.resolve_plan(
      ask_for_plan(system_prompt, project, input, opts, settings, max_items), opts, max_items
    )
    chosen = Project.find_by(:id => plan[:project_id])

    return [plan, project] if chosen.nil? || chosen.id == project.id
    return [plan, project] unless User.current.allowed_to?(:add_issues, chosen)

    opts2 = RedmineAiAssistant::IssueDraft.options(chosen, input, settings, keywords)
    plan2 = RedmineAiAssistant::IssueDraft.resolve_plan(
      ask_for_plan(system_prompt, chosen, input, opts2, settings, max_items), opts2, max_items
    )
    [plan2, chosen]
  end

  def ask_for_plan(system_prompt, project, input, opts, settings, max_items)
    ask_model(
      system_prompt,
      RedmineAiAssistant::ContextBuilder.issue_plan_prompt(project, input, opts, max_items),
      RedmineAiAssistant::IssueDraft.plan_schema(opts, max_items),
      settings['plan_max_tokens'].to_i
    )
  end

  # Jedno platené volanie modelu = jedna jednotka z hodinového limitu, a to VŽDY
  # pred odoslaním requestu. Režim plánu robí volania tri (výber projektu,
  # kľúčové slová, plán), takže sa odpočítajú tri — predtým sa celý klik počítal
  # ako jeden, hoci stál trojnásobok.
  def ask_model(system_prompt, user_prompt, schema, max_tokens)
    charge_quota!
    client.complete_json(system_prompt, user_prompt, schema, :max_tokens => max_tokens)
  end

  def charge_quota!
    raise QuotaExceeded unless RedmineAiAssistant.consume_rate_limit!(User.current)
  end

  # Voľná konverzácia režimu plánu. Formát `{role, text}` je iný než `history`
  # vo Fáze 1 — tú zámerne nemeníme, beží a je otestovaná.
  def messages_param
    Array(params[:messages]).first(20).map do |row|
      hash = row.respond_to?(:to_unsafe_h) ? row.to_unsafe_h : row.to_h
      { 'role' => hash['role'].to_s == 'ai' ? 'ai' : 'user',
        'text' => hash['text'].to_s[0, 2_000] }
    end
  rescue StandardError
    []
  end

  def ask_for_draft(system_prompt, project, input, opts, settings)
    ask_model(
      system_prompt,
      RedmineAiAssistant::ContextBuilder.issue_draft_prompt(project, input, opts),
      RedmineAiAssistant::IssueDraft.schema(opts),
      settings['draft_max_tokens'].to_i
    )
  end

  # História konverzácie prichádza od klienta (server je bezstavový). Kráti sa
  # a čistí — ide to do promptu, takže tam nemá tiecť neohraničený text.
  def history_param
    Array(params[:history]).first(10).map do |row|
      hash = row.respond_to?(:to_unsafe_h) ? row.to_unsafe_h : row.to_h
      { 'question' => hash['question'].to_s[0, 300],
        'answer'   => hash['answer'].to_s[0, 1_000] }
    end
  rescue StandardError
    []
  end

  # Spoločná obálka všetkých AI akcií: cache → hodinový limit → Gemini → cache
  # → JSON. Blok vracia celý payload odpovede, takže sa dá cachovať aj štruktúra,
  # nie len text.
  #
  # Hodinový limit je zámerne JEDEN pre všetky funkcie — platí sa z jedného
  # firemného kľúča, takže chráni ten istý rozpočet. Odpoveď z cache limit
  # nespotrebuje: cache sa číta tu a k volaniu modelu sa vôbec nedojde.
  #
  # Samotné účtovanie limitu ale NIE JE tu, lež v `ask_model`. Pomocné volania
  # (výber projektu, preklad kľúčových slov) sa robia ešte pred zostavením cache
  # kľúča, takže kontrola na tomto mieste ich nevidela a dala sa nimi obísť.
  def with_ai_guard(key)
    cached = Rails.cache.read(key)
    return render(:json => cached.merge(:cached => true)) if cached.present?

    payload = yield
    Rails.cache.write(key, payload, :expires_in => 1.hour)
    render :json => payload
  rescue RedmineAiAssistant::GeminiClient::Error => e
    render_ai_error(e)
  end

  # Cache je per (funkcia, rozsah, užívateľ, odtlačok toho, čo sa naozaj odosiela).
  #
  # Odtlačok promptov v kľúči je tam kvôli LADENIU: bez neho by admin zmenil
  # systémový prompt (alebo model, alebo limit popisu), klikol znova a hodinu
  # dostával starý výsledok — a myslel si, že zmena nefunguje. Zároveň tým je
  # v kľúči zahrnuté aj samotné zadanie, ktoré je súčasťou user promptu.
  def cache_key(prefix, scope_parts, system_prompt, user_prompt)
    fingerprint = Digest::MD5.hexdigest(
      [system_prompt, user_prompt, RedmineAiAssistant.setting('model')].join("\x00")
    )[0, 10]
    (["ai_assistant_#{prefix}"] + scope_parts + [User.current.id, fingerprint]).join(':')
  end

  def deliver(prefix, issue, system_prompt, user_prompt)
    key = cache_key(prefix, [issue.id, issue.journals.maximum(:id).to_i],
                    system_prompt, user_prompt)
    with_ai_guard(key) do
      charge_quota!
      { :text => client.complete(system_prompt, user_prompt) }
    end
  end

  def require_usable
    return if RedmineAiAssistant.usable?

    key = RedmineAiAssistant.enabled? ? :'ai_assistant.error_no_key' : :'ai_assistant.error_disabled'
    render_json_error(key, :forbidden)
  end

  def client
    RedmineAiAssistant::GeminiClient.new(RedmineAiAssistant::KeyStore.api_key)
  end

  def find_available_issue
    issue = Issue.find_by(:id => params[:issue_id])
    unless RedmineAiAssistant.available_for?(issue)
      render_json_error(:'ai_assistant.error_unavailable', :forbidden)
      return nil
    end
    issue
  end

  def render_rate_limited
    render_json_error(:'ai_assistant.error_rate_limited', :too_many_requests)
  end

  # Žiadna z týchto akcií nie je REST API — volá ich výhradne náš JS z prehliadača
  # a CSRF token vždy posiela. Redmine ale kontrolu tokenu preskakuje, keď ide
  # o `api_request?` (jadrové application_controller.rb:43), a to sa riadi VÝHRADNE
  # príponou v adrese: `POST /ai_assistant/plan_issues.json` tak prešiel bez tokenu
  # a spustil platené volania. Tu teda žiadna prípona z requestu API nerobí.
  def api_request?
    false
  end

  # Chyby idú ako HTTP 4xx/5xx s JSON správou — nikdy ako text návrhu s HTTP 200.
  # Správa od Gemini sa do odpovede NEDÁVA (mohla by obsahovať detaily o kľúči
  # alebo projekte); ide len do logu.
  def render_ai_error(error)
    key, status =
      case error
      when RedmineAiAssistant::GeminiClient::AuthError      then [:error_invalid_key, :unprocessable_entity]
      when RedmineAiAssistant::GeminiClient::RateLimitError then [:error_provider_rate_limited, :too_many_requests]
      when RedmineAiAssistant::GeminiClient::BlockedError   then [:error_blocked, :unprocessable_entity]
      when RedmineAiAssistant::GeminiClient::TruncatedError then [:error_truncated, :unprocessable_entity]
      when RedmineAiAssistant::GeminiClient::InvalidJsonError then [:error_invalid_json, :unprocessable_entity]
      else
        case error.message.to_s
        when 'timeout'     then [:error_timeout, :gateway_timeout]
        when 'unreachable' then [:error_unreachable, :bad_gateway]
        else [:error_generic, :bad_gateway]
        end
      end

    Rails.logger.error("[ai_assistant] #{error.class}: #{error.message}")
    render :json => { :error => l(:"ai_assistant.#{key}") }, :status => status
  end

  def render_json_error(key, status)
    render :json => { :error => l(key) }, :status => status
  end
end
