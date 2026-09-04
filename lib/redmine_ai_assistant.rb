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

  # Zhrnutie je iná úloha než odpoveď, preto vlastná persona aj vlastná forma.
  # Formu (sekcie) drží zámerne tento prompt, nie kód — aby sa dala prepísať
  # v konfigurácii bez zásahu do pluginu.
  DEFAULT_SUMMARY_PROMPT = <<~PROMPT
    Jsi {{NAME}}, člen týmu Previo.cz. Previo je cloudový hotelový systém (PMS)
    pro hotely a penziony v ČR, na Slovensku a ve střední Evropě.

    Dostaneš zadání úkolu a celou diskuzi pod ním. Shrň to česky pro někoho, kdo
    úkol nečetl a potřebuje se v něm zorientovat za půl minuty. Piš věcně, bez
    omáčky, celkem maximálně 250 slov. Použij přesně tyto sekce (prázdnou vynech):

    **O co jde** — 1–2 věty, co se řeší a proč.
    **Kde to stojí** — aktuální stav, kdo to má na sobě.
    **Co už padlo** — rozhodnutí a hotové kroky, ne převyprávění komentářů.
    **Co blokuje** — otevřené otázky, na koho nebo na co se čeká. Pokud nic, vynech.
    **Další krok** — co má následovat. Když to z diskuze nevyplývá, napiš to.

    Nevymýšlej si nic, co v úkolu není. Když něco není jasné, napiš, že to
    z úkolu nevyplývá. Výstupem je čistý text, žádný úvod typu "Zde je shrnutí".
  PROMPT

  # Persona pre predvyplnenie novej úlohy. Vychádza zo zadania, ktoré Previo
  # doteraz používalo v Gemini Gemu v Google Chate — ALE zámerne bez dvoch vecí,
  # ktoré ten Gem musel niesť v sebe:
  #   * bez zoznamu projektov / kategórií / PM — číselníky sa čítajú z Redmine
  #     a posielajú sa v kontexte, takže sa nikde neudržiavajú ručne,
  #   * bez šablón popisu — tie sú v Redmine v `global_issue_templates` a do
  #     kontextu ide obsah tej, ktorá patrí k zvolenému trackeru.
  # Vďaka tomu sa prompt nemusí meniť, keď Previo pridá projekt alebo upraví šablónu.
  DEFAULT_DRAFT_PROMPT = <<~PROMPT
    Jsi {{NAME}}, člen týmu Previo.cz. Previo je cloudový hotelový systém (PMS)
    pro hotely, penziony a apartmány. Vyvíjíme v PHP, MySQL, Vue a ExtJS.

    Tvým úkolem je z krátkého, neformálního zadání připravit ČISTĚ VYPLNĚNÝ úkol
    do Redmine. Zadání může být česky, slovensky nebo anglicky.

    ZÁSADNÍ PRAVIDLO: `subject` i `description` musí být VŽDY V ANGLIČTINĚ,
    bez ohledu na jazyk zadání. Ostatní hodnoty jsou názvy z Redmine, ty nepřekládej.

    `subject` je krátký věcný souhrn problému, ne převyprávěné zadání.

    `description` je CommonMark Markdown. Pokud kontext obsahuje šablonu popisu,
    použij PŘESNĚ její sekce a jejich názvy a mezi sekcemi nechávej prázdný řádek.
    Sekci, pro kterou v zadání není opora, ponech s krátkou poznámkou, co je třeba
    doplnit — nic si nevymýšlej.

    Výběr trackeru podle povahy věci:
    - Bug — něco v systému nefunguje správně.
    - Feature — vylepšení, nová funkce nebo změna chování stávající funkce.
    - TechDebt — technický dluh: chybějící index v databázi, neošetřené vstupy
      od uživatele, pomalý SQL dotaz.
    Jiné trackery použij jen tehdy, když zadání jasně odpovídá jejich významu.

    Projekt, tracker, kategorii, prioritu i projektového manažera vybírej VÝHRADNĚ
    z hodnot nabídnutých v kontextu, a to přesným názvem. Když si nejsi jistý,
    vyber hodnotu __UNKNOWN__ — prázdné pole je lepší než špatné. Do těchto polí
    nikdy nepiš nic jiného, žádné vysvětlování ani úvahy.

    U PROJEKTU dávej pozor: uživatel často zakládá úkol ze stránky jiného projektu,
    než do kterého úkol patří. Vyber projekt podle OBSAHU zadání, ne podle toho, kde
    uživatel stojí. Nikdy neupravuj popis tak, aby zadání „pasovalo" do projektu,
    ve kterém uživatel stojí.

    Když kontext obsahuje podobné existující úlohy, projdi je a do `similar_issues`
    dej ty, které mohou být duplicitou nebo úzce souvisí. U každé napiš krátce proč.
    Nic nepropojuj, jen upozorni.

    Do `questions` zapiš maximálně tři konkrétní doplňující otázky, a to jen tehdy,
    když bez odpovědi nejde úkol rozumně zadat. Uživatel na ně odpoví a ty dostaneš
    jeho odpovědi zpět v sekci „Doplňující informace z konverzace" — pak se na ně
    už neptej a zapracuj je. Návrh vyplň co nejlépe i tehdy, když se ptáš; na
    otázky se nečeká.
  PROMPT

  # Režim plánu (prútik v hlavičke). Proti `DEFAULT_DRAFT_PROMPT` sú tri rozdiely
  # a každý má dôvod:
  #   * model najprv ROZHODUJE, či je to jedna úloha alebo viac — nie je to
  #     rozpad na silu; jedna úloha je platný plán,
  #   * hierarchia sa zapína jediným booleanom a poradie v `issues` je záväzné,
  #     lebo Redmine potrebuje parenta založeného PRV než podúlohy,
  #   * `plan_summary` je jediné pole, ktoré ide v jazyku zadania — číta ho
  #     človek v okne, nie Redmine.
  DEFAULT_PLAN_PROMPT = <<~PROMPT
    Jsi {{NAME}}, člen týmu Previo.cz. Previo je cloudový hotelový systém (PMS)
    pro hotely, penziony a apartmány. Vyvíjíme v PHP, MySQL, Vue a ExtJS.

    Tvým úkolem je z volného zadání připravit PLÁN úkolů do Redmine. Zadání může
    být v jakémkoli jazyce (česky, slovensky, rumunsky, polsky, maďarsky, anglicky).

    NEJDŘÍV ROZHODNI, jestli je to jeden úkol, nebo víc úkolů. Jeden úkol je
    naprosto platný plán — nikdy nevymýšlej úkoly navíc jen proto, aby jich bylo
    víc. Rozděluj jen tehdy, když jsou to opravdu samostatně zadatelné kroky.

    Když má hierarchie smysl, nastav `use_parent` na true. PRVNÍ položka v `issues`
    je pak nadřazený úkol a všechny ostatní jsou jeho podúkoly. Nadřazený úkol je
    zastřešující cíl, podúkoly jsou konkrétní kroky k němu. Když jsou úkoly na sobě
    nezávislé, nastav `use_parent` na false a pořadí doporuč v `plan_summary`.

    ZÁSADNÍ PRAVIDLO: `subject` i `description` musí být u KAŽDÉ položky VŽDY
    V ANGLIČTINĚ, bez ohledu na jazyk zadání. Ostatní hodnoty jsou názvy z Redmine,
    ty nepřekládej.

    `description` je CommonMark Markdown. Nadřazený úkol (nebo jediný úkol) použij
    PŘESNĚ podle šablony z kontextu, pokud tam je. PODÚKOLY mají KRÁTKÝ popis,
    tři až šest řádků, BEZ šablony — jinak se odpověď nevejde do limitu.

    `plan_summary` napiš ve STEJNÉM JAZYCE, v jakém psal uživatel: dvě až čtyři
    věty o tom, jak je plán poskládaný a proč. Tohle čte člověk, ne Redmine.

    Výběr trackeru podle povahy věci:
    - Bug — něco v systému nefunguje správně.
    - Feature — vylepšení, nová funkce nebo změna chování stávající funkce.
    - TechDebt — technický dluh: chybějící index v databázi, neošetřené vstupy
      od uživatele, pomalý SQL dotaz.
    Nadřazený úkol a podúkoly mohou mít různé trackery.

    Projekt, tracker, kategorii, prioritu i projektového manažera vybírej VÝHRADNĚ
    z hodnot nabídnutých v kontextu, a to přesným názvem. Když si nejsi jistý, vyber
    hodnotu __UNKNOWN__ — prázdné pole je lepší než špatné. Do těchto polí nikdy
    nepiš nic jiného, žádné vysvětlování ani úvahy.

    Projekt je JEDEN pro celý plán a vybírej ho podle OBSAHU zadání, ne podle toho,
    kde uživatel stojí. Nikdy neupravuj popis tak, aby zadání „pasovalo" do projektu,
    ve kterém uživatel stojí.

    Když kontext obsahuje podobné existující úlohy, dej do `similar_issues` ty,
    které mohou být duplicitou nebo úzce souvisí, a u každé napiš krátce proč.
    Nic nepropojuj, jen upozorni.

    Do `questions` zapiš maximálně tři konkrétní doplňující otázky, a to jen tehdy,
    když bez odpovědi nejde plán rozumně navrhnout. Uživatel odpoví a jeho odpovědi
    dostaneš zpět v sekci „Konverzace s uživatelem" — pak se na ně už neptej.
    Plán vyplň co nejlépe i tehdy, když se ptáš; na otázky se nečeká.
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
    'system_prompt'       => DEFAULT_SYSTEM_PROMPT,
    # Zhrnutie stojí a padá na zadání, preto vyšší limit popisu než pri odpovedi.
    'summary_description_limit' => '4000',
    'summary_system_prompt'     => DEFAULT_SUMMARY_PROMPT,
    # Predvyplnenie novej úlohy má vlastný prepínač, aby sa dalo nasadiť
    # oddelene od dvoch už bežiacich funkcií (a rovnako oddelene vypnúť).
    'draft_enabled'        => '0',
    'draft_system_prompt'  => DEFAULT_DRAFT_PROMPT,
    # Koľko existujúcich úloh sa modelu ponúkne na posúdenie duplicity.
    # Jadrové hľadanie je LIKE bez fulltext indexu a radí podľa dátumu, nie
    # relevancie — preto sa berie väčšia hŕba a preradiť ju necháme model.
    # 0 = duplicity nehľadať vôbec.
    'draft_similar_limit'  => '40',
    'draft_translate_keywords' => '1',
    # Návrh úlohy je dlhší výstup než odpoveď v komentári (popis podľa šablóny
    # + dôvody u podobných úloh), preto vlastný, vyšší limit. Zámerne veľký:
    # `gemini-3.6-flash` je model s uvažovaním a jeho uvažovanie sa do tohto
    # limitu počíta — pri 4096 prišiel JSON odrezaný v polovici.
    'draft_max_tokens'     => '16384',
    # Režim plánu má vlastný prepínač z toho istého dôvodu ako `draft_enabled`:
    # nasadiť a vypnúť sa musí bez dotyku troch už bežiacich funkcií.
    'plan_enabled'       => '0',
    'plan_system_prompt' => DEFAULT_PLAN_PROMPT,
    # Strop počtu úloh v jednom pláne. Šesť je zvolené podľa výstupu, nie podľa
    # ambície: každá položka nesie vlastný popis, a plán, ktorý človek neprejde
    # očami, je aj tak zbytočný.
    'plan_max_items'     => '6',
    # Vyššie než `draft_max_tokens` — to je limit pre JEDNU úlohu s popisom podľa
    # šablóny. Pri šiestich položkách plus dôvodoch duplicít prišiel JSON odrezaný.
    'plan_max_tokens'    => '32768',
    # --- kod z GitLabu -------------------------------------------------------
    # Vlastny vypinac, aby sa dal zapnut a vypnut bez dotyku styroch uz beziacich
    # funkcii. Vypnuty = plugin GitLab vobec nevola a do promptu nejde ziadny kod.
    'code_context_enabled' => '0',
    'gitlab_url'           => 'https://gitlab.previo.info',
    'gitlab_token'         => '',
    'gitlab_token_hint'    => '',
    # Strop na diff v jednom prompte. Namerane na produkcnych MR: median par
    # stoviek znakov, maximum 59 000 pri 78 suboroch. 40 000 pokryje drviu
    # vacsinu a zvysok sa vypise len zoznamom nazvov.
    'code_diff_limit'      => '40000',
    # Kolko nalezov z hladania v kode sa ponukne pri navrhu NOVEJ ulohy
    # (na repozitar a klucove slovo). 0 = v kode nehladat.
    'code_search_results'  => '3'
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

    # Predvyplnenie novej úlohy má okrem globálneho `enabled` aj vlastný
    # prepínač — pri nasadzovaní sa tak nedotkneme dvoch bežiacich funkcií.
    def draft_usable?
      usable? && setting('draft_enabled').to_s == '1'
    end

    def plan_usable?
      usable? && setting('plan_enabled').to_s == '1'
    end

    # Pre ikonku prútika v hlavičke. Beží na KAŽDEJ stránke, preto memoizácia na
    # User.current (je request-scoped) — inak by to bol dotaz do DB pri každom
    # vykreslení menu, aj na stránkach, kde s úlohami nemá nikto nič.
    def plan_available_anywhere?(user = User.current)
      return false unless plan_usable?
      return false unless user&.logged?

      memo = user.instance_variable_get(:@raa_plan_anywhere)
      return memo unless memo.nil?

      memo = Project.allowed_to(user, :add_issues).active.exists?
      user.instance_variable_set(:@raa_plan_anywhere, memo)
      memo
    rescue StandardError
      false
    end

    # Podúlohy sú safe attribute LEN s právom :manage_subtasks (jadrové
    # issue.rb:529-534). Bez neho Redmine `parent_issue_id` TICHO zahodí a pole
    # vo formulári ani nevykreslí — preto sa to musí rozhodnúť tu, na serveri,
    # a nie až na klientovi podľa toho, čo je v DOM.
    def subtasks_allowed?(project, user = User.current)
      return false if project.nil?
      return false unless user&.logged?

      user.allowed_to?(:manage_subtasks, project)
    rescue StandardError
      false
    end

    # Kto smie v projekte zakladať úlohy, smie si ich dať aj predvyplniť.
    def available_for_draft?(project, user = User.current)
      draft_usable? && may_create_issues?(project, user)
    end

    # Režim plánu má vlastný prepínač, takže musí mať aj vlastnú kontrolu. Keď sa
    # pýtal cez `available_for_draft?`, vyžadoval zapnuté `draft_enabled` — a tým
    # sa oba prepínače dali zapnúť len spolu, hoci majú byť nezávislé.
    def available_for_plan?(project, user = User.current)
      plan_usable? && may_create_issues?(project, user)
    end

    # Zámerne sa používa JADROVÉ právo `:add_issues` — plugin nezavádza vlastnú
    # permission, takže niet čo nastavovať navyše a práva zostávajú na jednom mieste.
    def may_create_issues?(project, user = User.current)
      return false unless user&.logged?
      return false if project.nil?

      user.allowed_to?(:add_issues, project)
    rescue StandardError
      false
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

    # `key` rozlišuje personu pre návrh odpovede a pre zhrnutie. Bez druhého
    # argumentu sa chová ako doteraz.
    def system_prompt_for(user, key = 'system_prompt')
      setting(key).to_s.gsub('{{NAME}}', user&.name.to_s)
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
