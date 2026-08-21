# frozen_string_literal: true

module RedmineAiAssistant
  # Predvyplnenie novej úlohy: čo smie model navrhnúť (`options`) a preklad jeho
  # odpovede na atribúty úlohy (`resolve`).
  #
  # `options` je ZÁROVEŇ whitelist. Je to schválne jedna metóda pre prompt aj pre
  # validáciu — keby to boli dva zoznamy, rozišli by sa a model by mohol
  # „presvedčiť" server o hodnote, ktorú mu nikto nenabídol.
  #
  # Nič sa tu neukladá. Výstup ide do formulára, uloženie robí jadrový
  # IssuesController#create so všetkými svojimi právami a validáciami.
  module IssueDraft
    # Nad týmto počtom hodnôt sa `enum` do schémy nedáva a pole zostane voľným
    # textom (kontrola potom leží celá na `resolve`). Je to poistka proti príliš
    # veľkej schéme u projektu s extrémnym počtom kategórií.
    MAX_ENUM_VALUES = 200

    # Kľúčových slov na hľadanie duplicít. Rovnaký strop platí pre preložené
    # slová aj pre slová z originálneho zadania.
    MAX_SEARCH_KEYWORDS = 8

    # Absolútny strop počtu úloh v pláne, NAD nastavením `plan_max_items`. Je tu
    # preto, že nastavenie môže admin prepísať na hocičo — a plán o dvadsiatich
    # úlohách sa nevojde ani do limitu tokenov, ani do URL na predvyplnenie.
    MAX_PLAN_ITEMS = 12

    # Schéma pomocného volania, ktoré zadanie v ľubovoľnom jazyku preloží na
    # anglické kľúčové slová pre hľadanie duplicít.
    KEYWORDS_SCHEMA = {
      :type       => 'OBJECT',
      :properties => { 'keywords' => { :type => 'ARRAY', :items => { :type => 'STRING' } } },
      :required   => %w[keywords]
    }.freeze

    # Zástupná hodnota pre „neviem". Gemini v `enum` NEPOVOLÍ prázdny string
    # („enum[0]: cannot be empty"), takže model musí mať iný spôsob, ako sa
    # nevyjadriť. Žiadny záznam v Redmine sa takto nemenuje, takže `resolve` ju
    # sám nepriradí k ničomu a pole zostane prázdne — bez ďalšieho kódu.
    UNKNOWN = '__UNKNOWN__'


    # Vstupné zadanie od užívateľa sa kráti — do promptu nemá tiecť neohraničene
    # veľký text (a dlhší vstup než toto nie je „krátke zadanie", ale hotový popis).
    MAX_INPUT_CHARS = 4_000

    # `bool` povinné polia sa modelu NEnabízia. V Previu je povinné napr.
    # „DEV ready" — to je príznak stavu vo workflow, nie informácia obsiahnutá
    # v hlásení chyby. Model by ho tipoval a mohol tipnúť zle; patrí človeku.
    # Ostatné povinné polia (typicky `user` = Project Manager) sa zo zadania
    # odvodiť dajú.
    SKIPPED_REQUIRED_FORMATS = %w[bool].freeze

    class << self
      # Všetko, čo smie model navrhnúť, pre daný projekt a dané zadanie.
      #
      # `projects` je tu preto, že zadanie často nepatrí do projektu, v ktorom
      # užívateľ práve stojí. Bez tejto možnosti sa model snažil CRM úlohu
      # natlačiť do Channel Managera a vymyslel k tomu nezmyselnú kategóriu.
      # `search_keywords` sú anglické kľúčové slová z pomocného volania (viď
      # `ContextBuilder.search_keywords_prompt`). Keď sa nepredajú, hľadá sa
      # podľa slov z originálneho zadania — teda slabšie, ale funguje to vždy.
      def options(project, input = {}, settings = RedmineAiAssistant.settings,
                  search_keywords = nil)
        {
          :project    => project,
          :projects   => allowed_projects,
          :trackers   => project.trackers.sorted.to_a,
          :categories => project.issue_categories.includes(:assigned_to).to_a,
          :priorities => IssuePriority.active.to_a,
          :assignees  => assignable_users(project),
          :custom_fields => required_custom_fields(project),
          :templates  => description_templates(project),
          :similar    => similar_issues(project, input, settings['draft_similar_limit'].to_i,
                                        search_keywords),
          # Či sa hierarchia vôbec smie navrhnúť. Patrí to sem, lebo `options` je
          # jediný whitelist — keby o tom rozhodoval klient, model by mohol vrátiť
          # plán, ktorý Redmine odmietne: `parent_issue_id` je safe attribute len
          # s právom :manage_subtasks a bez neho sa TICHO zahodí.
          :subtasks_allowed => RedmineAiAssistant.subtasks_allowed?(project)
        }
      end

      # Len projekty, kam užívateľ naozaj smie zakladať úlohy — model tak nemôže
      # navrhnúť projekt, do ktorého by to aj tak neuložil.
      def allowed_projects
        Project.allowed_to(User.current, :add_issues).active.sorted.to_a
      rescue StandardError
        []
      end

      # Preklad odpovede modelu na atribúty úlohy. Čo sa nepodarí priradiť
      # k nabídnutej hodnote, sa ZAHODÍ — prázdne pole je lepšie než nesprávne.
      def resolve(data, opts)
        resolve_issue(data, opts).merge(
          # Projekt: keď model navrhne iný, prijme sa len ak je medzi tými, kam
          # užívateľ smie zakladať. Neznámy návrh = zostáva projekt z formulára.
          :project_id     => (find_by_name(opts[:projects], data['project']) || opts[:project])&.id,
          :similar_issues => resolve_similar(data['similar_issues'], opts[:similar]),
          :questions      => Array(data['questions']).map { |q| squish(q, 300) }.compact.first(3)
        ).reject { |_k, v| v.nil? || (v.respond_to?(:empty?) && v.empty?) }
      end

      # Atribúty JEDNEJ úlohy. Zdieľajú to obe cesty — návrh jednej úlohy
      # (tlačidlo vo formulári) aj každá položka plánu (prútik v hlavičke).
      # Je to zámer: nemôže tak vzniknúť stav, kde v pláne prejde hodnota, ktorú
      # by jednotlivý návrh zahodil.
      #
      # Projekt, duplicity ani otázky tu NIE SÚ — to sú vlastnosti celého návrhu,
      # nie jednej úlohy.
      def resolve_issue(data, opts)
        data = {} unless data.is_a?(Hash)
        out = {}
        out[:subject]     = squish(data['subject'], 255)
        out[:description] = data['description'].to_s.strip.presence

        # Okno s návrhom potrebuje aj čitateľné názvy — používateľ má vidieť
        # „Bug", nie id. Klient ich zobrazuje, do formulára sa vkladajú len id.
        tracker  = find_by_name(opts[:trackers], data['tracker'])
        priority = find_by_name(opts[:priorities], data['priority'])
        out[:tracker_id]    = tracker&.id
        out[:tracker_name]  = tracker&.name
        out[:priority_id]   = priority&.id
        out[:priority_name] = priority&.name

        # Riešiteľa NENAVRHUJE model. Keď má zvolená kategória v Redmine
        # nastavenú zodpovednú osobu (`IssueCategory#assigned_to`), doplní sa
        # deterministicky zo nej — je to jadrom udržiavaný číselník, takže je to
        # presnejšie než tip modelu a nestojí to ani token.
        category = find_by_name(opts[:categories], data['category'])
        out[:category_id]    = category&.id
        out[:category_name]  = category&.name
        out[:assigned_to_id] = category_assignee(category, opts[:assignees])

        out[:custom_field_values] = resolve_required_fields(data, opts[:custom_fields])
        out[:custom_field_names]  = describe_custom_fields(out[:custom_field_values],
                                                          opts[:custom_fields])

        out.reject { |_k, v| v.nil? || (v.respond_to?(:empty?) && v.empty?) }
      end

      # Plán: jedna alebo viac úloh v JEDNOM projekte, prípadne s hierarchiou.
      # Rovnaké pravidlo ako v `resolve` — čo nebolo v ponuke, sa zahodí, a to
      # v KAŽDEJ položke, nie len v prvej.
      def resolve_plan(data, opts, max_items)
        data = {} unless data.is_a?(Hash)
        cap  = [[max_items.to_i, 1].max, MAX_PLAN_ITEMS].min
        rows = Array(data['issues']).first(cap)
                                    .map { |row| resolve_issue(row, opts) }
                                    .select { |row| row[:subject].present? }
        project = find_by_name(opts[:projects], data['project']) || opts[:project]

        # Hierarchia sa POVOĽUJE, nie zakazuje. Keď užívateľ nemá :manage_subtasks,
        # Redmine by `parent_issue_id` ticho zahodilo a človek by sa díval na plán,
        # ktorý sa nedá zrealizovať — radšej samostatné úlohy a jasná veta v okne.
        use_parent = data['use_parent'] == true && rows.size > 1 && !!opts[:subtasks_allowed]

        { :summary          => squish(data['plan_summary'], 1_200),
          :project_id       => project&.id,
          :project_name     => project&.name,
          :use_parent       => use_parent,
          :subtasks_allowed => !!opts[:subtasks_allowed],
          # Každá položka nesie `project_id`, aby bola fronta na klientovi
          # sebestačná a `prefillUrl` nemusel nič dohľadávať.
          :issues           => rows.map { |r| r.merge(:project_id => project&.id) },
          :similar_issues   => resolve_similar(data['similar_issues'], opts[:similar]),
          :questions        => Array(data['questions']).map { |q| squish(q, 300) }.compact.first(3) }
      end

      # Schéma sa skladá DYNAMICKY z whitelistu, nie staticky — a je to podstatné.
      #
      # Pri voľných textových poliach si model s uvažovaním vypísal do `tracker`
      # celý svoj myšlienkový pochod („Bug McBugface? No, Bug tracker from list…"),
      # takže sa nedal priradiť. `enum` mu možnosť odbočiť neponechá.
      #
      # Povinné polia sú v `required` preto, že Gemini nepovinné kľúče jednoducho
      # vynechá — v prvom teste tak neprišla ani kategória, ani priorita, ani PM.
      def schema(opts)
        props, required = issue_schema_properties(opts)
        props['project'] = enum_property(opts[:projects].map(&:name))
        required << 'project'

        if opts[:similar].any?
          props['similar_issues'] = similar_property
          required << 'similar_issues'
        end
        props['questions'] = { :type => 'ARRAY', :items => { :type => 'STRING' } }

        { :type => 'OBJECT', :properties => props, :required => required }
      end

      # Schéma plánu. Kľúčové je, že `issues` je pole objektov s tým ISTÝM popisom
      # položky ako pri jednej úlohe — enum zoznamy (projekty, kategórie, kandidáti
      # na PM) sú tak v schéme práve RAZ, takže počet podúloh nemení jej veľkosť.
      # N samostatných volaní by tie zoznamy zaplatilo N-krát a model by navyše
      # nevidel plán ako celok.
      # Schéma pomocného volania, ktoré z voľného zadania vyberie PROJEKT.
      #
      # Je to samostatný krok zámerne: keď model dostal zadanie spolu s kategóriami
      # a šablónami jedného projektu, držal sa ho aj vtedy, keď úloha patrila inam —
      # kontext projektu je príliš silný signál. Tu nevidí nič okrem zoznamu
      # projektov, takže rozhoduje podľa obsahu.
      def project_schema(projects)
        { :type       => 'OBJECT',
          :properties => { 'project' => enum_property(projects.map(&:name)),
                           'reason'  => { :type => 'STRING' } },
          :required   => %w[project reason] }
      end

      def plan_schema(opts, max_items)
        item_props, item_required = issue_schema_properties(opts)
        cap = [[max_items.to_i, 1].max, MAX_PLAN_ITEMS].min

        props = {
          'plan_summary' => { :type => 'STRING' },
          # Projekt je JEDEN pre celý plán: podúloha v inom projekte je síce
          # (pri `cross_project_subtasks = tree`) možná, ale je to stupeň voľnosti,
          # ktorý plán nepotrebuje a model by ním len chyboval.
          'project'      => enum_property(opts[:projects].map(&:name)),
          # BOOLEAN, nie enum: „má to byť hierarchia?" je jedna otázka s dvoma
          # odpoveďami. Musí byť v `required` — Gemini nepovinné kľúče vynecháva.
          'use_parent'   => { :type => 'BOOLEAN',
                              :description => 'true = první položka v issues je nadřazený ' \
                                              'úkol a všechny ostatní jsou jeho podúkoly.' },
          # `maxItems` je pre model návod, nie záruka — skutočný strop drží
          # `resolve_plan`.
          'issues'       => { :type     => 'ARRAY',
                              :minItems => 1,
                              :maxItems => cap,
                              :items    => { :type       => 'OBJECT',
                                             :properties => item_props,
                                             :required   => item_required } }
        }
        required = %w[plan_summary project use_parent issues]

        if opts[:similar].any?
          props['similar_issues'] = similar_property
          required << 'similar_issues'
        end
        props['questions'] = { :type => 'ARRAY', :items => { :type => 'STRING' } }

        { :type => 'OBJECT', :properties => props, :required => required }
      end

      # Vlastnosti JEDNEJ úlohy — spoločné pre `schema` aj pre položky `plan_schema`.
      # Projekt tu nie je: pri jednej úlohe je to pole navyše, pri pláne patrí
      # o úroveň vyššie.
      def issue_schema_properties(opts)
        props = {
          'subject'     => { :type => 'STRING' },
          'description' => { :type => 'STRING' },
          'tracker'     => enum_property(opts[:trackers].map(&:name)),
          'priority'    => enum_property(opts[:priorities].map(&:name))
        }
        required = %w[subject description tracker priority]

        if opts[:categories].any?
          props['category'] = enum_property(opts[:categories].map(&:name))
          required << 'category'
        end

        # Každé povinné custom pole má vlastný kľúč `cf_<id>` s vlastným zoznamom
        # hodnôt. Je to presnejšie než jedno pole „name/value", kde by model musel
        # trafiť aj názov poľa aj hodnotu.
        opts[:custom_fields].each do |entry|
          props[cf_key(entry[:field])] = enum_property(offered_labels(entry[:values]))
          required << cf_key(entry[:field])
        end

        [props, required]
      end

      def similar_property
        { :type  => 'ARRAY',
          :items => {
            :type       => 'OBJECT',
            :properties => { 'id' => { :type => 'INTEGER' }, 'reason' => { :type => 'STRING' } },
            :required   => %w[id reason]
          } }
      end

      # `description` v schéme je dôležitejšie, než sa zdá: instrukcia o zástupnej
      # hodnote tým cestuje so schémou a platí aj vtedy, keď si admin systémový
      # prompt prepíše.
      def enum_property(values)
        list = Array(values).map(&:to_s).reject(&:empty?).uniq
        return { :type => 'STRING' } if list.empty? || list.size > MAX_ENUM_VALUES

        { :type        => 'STRING',
          :enum        => [UNKNOWN] + list,
          :description => "Vyber #{UNKNOWN}, keď si nie si istý." }
      end

      def cf_key(field)
        "cf_#{field.id}"
      end

      # Redmine pridáva pre prihláseného užívateľa položku „<< me >>“, ktorá pre
      # model nemá význam.
      def offered_labels(values)
        Array(values).map { |label, _v| label.to_s }.reject { |label| label.start_with?('<<') }
      end

      private

      # Model dostane meno, nie id — porovnáva sa bez ohľadu na veľkosť písmen
      # a okolité medzery. `records` je vždy to, čo sme mu naozaj nabídli.
      def find_by_name(records, value)
        name = value.to_s.strip.downcase
        return nil if name.empty?

        Array(records).find { |r| r.name.to_s.strip.downcase == name }
      end

      # Povinné custom fieldy sú dôvod, prečo toto vôbec riešime: PM (`Project
      # Manager`) je v Previu povinný, takže bez neho by sa úloha neuložila.
      # Nehľadá sa podľa konkrétneho id — číta sa, čo je v projekte povinné,
      # takže to funguje aj na inej instanci a po zmene číselníka.
      def required_custom_fields(project)
        probe = Issue.new(:project => project)
        project.all_issue_custom_fields
               .select { |cf| cf.is_required? && !SKIPPED_REQUIRED_FORMATS.include?(cf.field_format) }
               .map do |cf|
          values = begin
            cf.possible_values_options(probe)
          rescue StandardError
            []
          end
          { :field => cf, :values => Array(values) }
        end
      rescue StandardError => e
        Rails.logger.warn("[ai_assistant] povinne custom fieldy sa nepodarilo nacitat: #{e.class}: #{e.message}")
        []
      end

      # Pre okno s návrhom: „Project Manager → Novák Jan" namiesto
      # „58 → 109". Hodnota sa hľadá v tej istej ponuke, z ktorej sa vyberalo.
      def describe_custom_fields(values, fields)
        Array(fields).filter_map do |entry|
          stored = values[entry[:field].id.to_s]
          next if stored.blank?

          pair  = Array(entry[:values]).find { |_label, value| value.to_s == stored.to_s }
          label = pair ? pair.first.to_s : stored.to_s
          { :name => entry[:field].name, :value => label }
        end
      end

      # `assigned_to` na kategórii môže byť aj SKUPINA, a nemusí byť medzi
      # prípustnými riešiteľmi projektu. Keby sme takú hodnotu predvyplnili,
      # formulár by pri ukladaní spadol na validácii — preto sa overí členstvo.
      def category_assignee(category, assignees)
        principal = category&.assigned_to
        return nil if principal.nil?

        Array(assignees).any? { |u| u.id == principal.id } ? principal.id : nil
      end

      # Každé povinné pole má v odpovedi vlastný kľúč `cf_<id>` (viď `schema`),
      # takže sa nič nedohľadáva podľa názvu poľa — model mohol trafiť len hodnotu.
      def resolve_required_fields(data, fields)
        Array(fields).each_with_object({}) do |entry, acc|
          value = cast_custom_value(entry, data[cf_key(entry[:field])])
          acc[entry[:field].id.to_s] = value if value.present?
        end
      end

      # Pri poliach s ponukou (user, list, …) sa prijme LEN hodnota z ponuky;
      # `possible_values_options` vracia dvojice [popis, hodnota]. Pole bez ponuky
      # (napr. povinný text) sa berie ako voľný text.
      def cast_custom_value(entry, raw)
        wanted = raw.to_s.strip
        return nil if wanted.empty?
        return wanted.truncate(255) if entry[:values].empty?

        match = entry[:values].find do |label, value|
          [label.to_s, value.to_s].any? { |c| c.strip.downcase == wanted.downcase }
        end
        match && match.last.to_s
      end

      # Prijmú sa len úlohy, ktoré sme modelu sami nabídli — inak by mohol
      # „upozorniť" na úlohu, ktorú užívateľ nevidí.
      def resolve_similar(proposed, candidates)
        by_id = Array(candidates).index_by(&:id)
        Array(proposed).filter_map do |row|
          issue = by_id[row['id'].to_i]
          next if issue.nil?

          { :id => issue.id, :subject => issue.subject.to_s,
            :reason => squish(row['reason'], 200).to_s }
        end.first(5)
      end

      # Kandidáti na duplicitu. Jadrové hľadanie je LIKE bez fulltext indexu
      # a radí podľa dátumu, nie relevancie, takže sa berie väčšia hŕba
      # najnovších otvorených úloh a preradiť ju necháme model.
      #
      # GDPR: privátne úlohy sú vylúčené vždy — rovnako ako pri ostatných
      # funkciách pluginu sa ich obsah do externej služby nedostane.
      # POZOR: jadrový scope `Issue.like` sa použiť NEDÁ. Spája slová cez AND
      # (`Query.tokenized_like_conditions`, `all_words` default), takže by sa
      # v názve musela vyskytovať celá veta zo zadania a nenašlo by sa nikdy nič.
      # Preto vlastný OR filter — a keďže OR nájde aj úlohy so single zhodou na
      # bežnom slove, radíme podľa POČTU zhodných slov, nie podľa dátumu.
      def similar_issues(project, input, limit, translated = nil)
        return [] if limit <= 0

        tokens = search_tokens(input, translated)
        return [] if tokens.empty?

        quoted = tokens.map { |t| ActiveRecord::Base.connection.quote("%#{t}%") }
        matches = quoted.map { |q| "LOWER(issues.subject) LIKE #{q}" }
        score   = matches.map { |m| "(CASE WHEN #{m} THEN 1 ELSE 0 END)" }.join(' + ')

        Issue.visible
             .open
             .where(:project_id => project.id, :is_private => false)
             .where(matches.join(' OR '))
             .order(Arel.sql("(#{score}) DESC, issues.id DESC"))
             .limit(limit)
             .to_a
      rescue StandardError => e
        Rails.logger.warn("[ai_assistant] podobne ulohy sa nepodarilo najst: #{e.class}: #{e.message}")
        []
      end

      # Prednosť majú anglické slová od modelu. Úlohy v Previu sa píšu anglicky,
      # ale zadanie píše každý vo svojom jazyku (kolegovia sú v Rumunsku, Poľsku
      # a Maďarsku), a hľadanie je obyčajné LIKE nad názvami — takže české
      # „nejde uložit rezervaci…" našlo v Reservations 5 úloh a ani jedna
      # nesúvisela (zhodovalo sa len „host" v slove „hostel"), kým to isté
      # anglicky narazilo na strop 40 a prvé tri boli trefy.
      #
      # Keď preklad nie je (vypnutý, zlyhal, nevrátil nič použiteľné), padá sa na
      # originálne zadanie: slabšie hľadanie je lepšie než žiadne.
      def search_tokens(input, translated)
        normalize_keywords(translated).presence || keywords(input)
      end

      # Z odpovede modelu sa berú len jednotlivé slová aspoň o štyroch znakoch —
      # rovnaká hranica ako pri originálnom zadaní. Kratšie slová robia v LIKE
      # hľadaní šum a model občas vráti celú frázu namiesto slova.
      def normalize_keywords(values)
        Array(values).flat_map { |v| v.to_s.scan(/[[:alnum:]]{4,}/) }
                     .map(&:downcase).uniq.first(MAX_SEARCH_KEYWORDS)
      end

      def keywords(input)
        text = [input[:subject], input[:description]].compact.join(' ')
        text.scan(/[[:alnum:]]{4,}/).map(&:downcase).uniq.first(MAX_SEARCH_KEYWORDS)
      end

      def squish(value, limit)
        text = value.to_s.gsub(/\s+/, ' ').strip
        text.empty? ? nil : text.truncate(limit)
      end

      def assignable_users(project)
        project.assignable_users.to_a
      rescue StandardError
        []
      end

      # Šablóny popisu drží plugin redmine_issue_templates. Ak nie je
      # nainštalovaný, funkcia beží ďalej — len bez šablón.
      # Poradie: šablóna projektu má prednosť pred globálnou; v rámci trackera sa
      # berie prvá podľa `position` (pre Feature sú v Previu zapnuté dve).
      def description_templates(project)
        return {} unless defined?(::GlobalIssueTemplate) && defined?(::IssueTemplate)

        project.trackers.sorted.each_with_object({}) do |tracker, acc|
          tpl = ::IssueTemplate.where(:project_id => project.id, :tracker_id => tracker.id,
                                      :enabled => true).order(:position).first ||
                ::GlobalIssueTemplate.where(:tracker_id => tracker.id,
                                            :enabled => true).order(:position).first
          acc[tracker.name] = tpl.description.to_s if tpl&.description.present?
        end
      rescue StandardError => e
        Rails.logger.warn("[ai_assistant] sablony popisu sa nepodarilo nacitat: #{e.class}: #{e.message}")
        {}
      end
    end
  end
end
