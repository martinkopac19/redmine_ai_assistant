# frozen_string_literal: true

module RedmineAiAssistant
  # Skladá prompt z úlohy. Toto je jediné miesto, kde sa rozhoduje,
  # ČO opustí Redmine — preto sú tu aj GDPR filtre.
  module ContextBuilder
    # Do kontextu idú VŠETKY verejné komentáre — počet sa nenastavuje.
    # Namerané na produkčných dátach: priemer 3,4 komentára na úlohu, p95 = 11,
    # maximum 79 (77 000 znakov). Tento strop je len ochrana proti patologickému
    # prípadu, aby jedna úloha neposlala megabajt textu; reálne sa neuplatní.
    MAX_NOTES_CHARS = 60_000

    class << self
      def suggestion_prompt(issue, settings = RedmineAiAssistant.settings)
        parts = issue_context(issue, settings,
                              :description_limit => settings['description_limit'].to_i)

        parts << "\n## Zadání\nNapiš stručnou a věcnou odpověď na poslední komentář " \
                 'nebo na zmínku o tobě. Odpověď musí být v češtině a připravená ' \
                 'k přímému vložení do Redmine.'

        parts.join("\n")
      end

      # Zhrnutie dostane ten istý kontext, len s vlastným limitom popisu — a BEZ
      # bloku „Zadání". Čo má model spraviť a v akej forme, drží celé
      # nastavenie `summary_system_prompt`, aby sa to dalo zmeniť v konfigurácii.
      def summary_prompt(issue, settings = RedmineAiAssistant.settings)
        issue_context(issue, settings,
                      :description_limit => settings['summary_description_limit'].to_i)
          .join("\n")
      end

      # Predvyplnenie novej úlohy — opačný smer než ostatné dve funkcie: nie
      # „úloha → text", ale „text → návrh úlohy".
      #
      # Do promptu ide LEN to, čo daný projekt naozaj má (`opts` z IssueDraft),
      # takže sa nikde neudržiava žiadny zoznam projektov, kategórií ani PM —
      # a keď Previo pridá kategóriu alebo upraví šablónu, prejaví sa to samo.
      # Pomocné volanie: zadanie v ľubovoľnom jazyku → anglické kľúčové slová
      # na hľadanie duplicít. Je zámerne malé a bez akéhokoľvek kontextu projektu —
      # ide o preklad, nie o návrh úlohy, takže sa nemá čím rozptýliť.
      def search_keywords_prompt(input)
        parts = ['# Zadání']
        subject = input[:subject].to_s.strip
        parts << "Název: #{subject}" if subject.present?
        description = input[:description].to_s.strip
        if description.present?
          parts << "Popis:
#{description.truncate(IssueDraft::MAX_INPUT_CHARS)}"
        end
        parts << <<~TASK

          # Úkol
          Zadání může být v jakémkoli jazyce (česky, slovensky, rumunsky, polsky,
          maďarsky, anglicky). Vrať klíčová slova pro hledání podobných úloh
          v Redmine, VŽDY V ANGLIČTINĚ a v jednotném čísle.
          Názvy úloh jsou psané anglicky, takže použij odbornou terminologii
          hotelového systému (reservation, invoice, voucher, rate, occupancy,
          channel, payment…), ne doslovný překlad slovo za slovem.
          Vynech slova bez rozlišovací hodnoty (problém, nefunguje, chyba, prosím,
          nejde) a slova kratší než čtyři znaky.
          Maximálně #{IssueDraft::MAX_SEARCH_KEYWORDS} slov, jen jednotlivá slova,
          žádné fráze ani celé věty.
        TASK
        parts.join("
")
      end

      # Prompt pre výber projektu. Zámerne NEOBSAHUJE nič okrem zadania a zoznamu
      # projektov — žiadne kategórie, šablóny ani „projekt, v ktorom užívateľ stojí".
      # Práve tie model odkláňali: úlohu si prispôsobil projektu, ktorý mal
      # v kontexte, namiesto toho, aby vybral podľa obsahu.
      def project_pick_prompt(input, projects)
        parts = ['# Zadání od uživatele']
        parts << input[:description].to_s.strip.truncate(IssueDraft::MAX_INPUT_CHARS)
        parts.concat(plan_conversation_section(input[:messages]))

        parts << "\n# Projekty, do kterých smíš úkol zadat"
        parts << projects.map do |p|
          description = p.description.to_s.strip.gsub(/\s+/, ' ')
          description.present? ? "- #{p.name} — #{description.truncate(160)}" : "- #{p.name}"
        end.join("\n")

        parts << <<~TASK

          # Úkol
          Vyber JEDEN projekt, do kterého úkol podle OBSAHU zadání patří, a to přesným
          názvem ze seznamu. Do `reason` napiš jednou větou proč, ve stejném jazyce,
          v jakém psal uživatel.
          Rozhoduj podle toho, čeho se zadání věcně týká — ne podle toho, který projekt
          je v seznamu první nebo jak se jmenuje nejobecněji.
          Když si opravdu nejsi jistý, vyber #{IssueDraft::UNKNOWN}.
        TASK
        parts.join("\n")
      end

      # Prompt režimu plánu. Sekcie o projekte, trackeroch, šablónach, kategóriách,
      # prioritách, povinných poliach a duplicitách sú ZDIEĽANÉ s návrhom jednej
      # úlohy — platia pre celú dávku rovnako. Vlastné sú len dve veci: strop počtu
      # úloh a informácia o práve na podúlohy.
      def issue_plan_prompt(project, input, opts, max_items)
        parts = ['# Zadání od uživatele']
        parts << input[:description].to_s.strip.truncate(IssueDraft::MAX_INPUT_CHARS)

        parts.concat(plan_conversation_section(input[:messages]))

        parts << "\n# Kolik úkolů\nMaximálně #{max_items} úkolů celkem, včetně nadřazeného."

        # Toto NEPATRÍ do systémového promptu: je to fakt o právach TOHTO užívateľa
        # v TOMTO projekte, nie inštrukcia, ktorú by admin ladil.
        unless opts[:subtasks_allowed]
          parts << "\n# Hierarchie\nUživatel nemá právo spravovat podúkoly, takže " \
                   '`use_parent` nastav na false. Když je potřeba víc úkolů, navrhni je ' \
                   'jako samostatné a doporučené pořadí napiš do `plan_summary`.'
        end

        # V režime plánu je projekt už vybraný samostatným volaním, takže sa
        # neponúka ako „projekt, v ktorom stojíš" (to je formulácia z Fázy 1, kde
        # užívateľ naozaj niekde stojí) — je to rozhodnutie, ktoré má model prijať.
        parts << "\n# Projekt tohoto plánu\n#{project.name}"
        project_description = project.description.to_s.strip
        parts << project_description.truncate(1_000) if project_description.present?

        parts.concat(projects_section(opts[:projects], project))
        parts.concat(list_section('Dostupné trackery', opts[:trackers]) { |t| t.name })
        parts.concat(template_section(opts[:templates]))
        parts.concat(list_section('Kategorie projektu', opts[:categories]) { |c| c.name })
        parts.concat(list_section('Priority', opts[:priorities]) do |p|
          "#{p.name}#{' (výchozí)' if p.is_default?}"
        end)
        parts.concat(required_fields_section(opts[:custom_fields]))
        parts.concat(similar_section(opts[:similar]))
        parts.concat(Array(opts[:code]))

        parts.join("\n")
      end

      # Voľná konverzácia, na rozdiel od `conversation_section`, ktorá stojí na
      # pároch otázka/odpoveď. V režime plánu môže človek doplniť čokoľvek, nielen
      # odpovedať — a model má vidieť aj to, čo sám navrhol, aby na tom stavěl.
      # Server zostáva bezstavový: celý transkript posiela klient.
      def plan_conversation_section(messages)
        rows = Array(messages).filter_map do |row|
          text = row['text'].to_s.strip
          next if text.empty?

          row['role'].to_s == 'ai' ? "- Ty: #{text}" : "- Uživatel: #{text}"
        end
        return [] if rows.empty?

        ["\n## Konverzace s uživatelem",
         'Tohle už padlo. Neptej se na to znovu a zapracuj to do plánu.',
         rows.join("\n")]
      end

      def issue_draft_prompt(project, input, opts)
        parts = ['# Zadání od uživatele']

        subject = input[:subject].to_s.strip
        parts << "Název: #{subject}" if subject.present?
        description = input[:description].to_s.strip
        if description.present?
          parts << "Popis:\n#{description.truncate(IssueDraft::MAX_INPUT_CHARS)}"
        end

        parts.concat(conversation_section(input[:history]))

        parts << "\n# Projekt, ve kterém uživatel stojí\n#{project.name}"
        project_description = project.description.to_s.strip
        parts << project_description.truncate(1_000) if project_description.present?

        parts.concat(projects_section(opts[:projects], project))
        parts.concat(list_section('Dostupné trackery', opts[:trackers]) { |t| t.name })
        parts.concat(template_section(opts[:templates]))
        parts.concat(list_section('Kategorie projektu', opts[:categories]) { |c| c.name })
        parts.concat(list_section('Priority', opts[:priorities]) do |p|
          "#{p.name}#{' (výchozí)' if p.is_default?}"
        end)
        parts.concat(required_fields_section(opts[:custom_fields]))
        parts.concat(similar_section(opts[:similar]))
        parts.concat(Array(opts[:code]))

        parts.join("\n")
      end

      private

      def list_section(title, records)
        return [] if records.blank?

        ["\n## #{title}", records.map { |r| "- #{yield(r)}" }.join("\n")]
      end

      # Zoznam projektov, kam užívateľ smie zakladať. Popis projektu je pre výber
      # kľúčový (často je v ňom „PM: …" alebo čoho sa projekt týka), ale kráti sa —
      # 63 celých popisov by prompt zbytočne nafúklo.
      #
      # Kategórie, šablóny ani PM v prompte pre OSTATNÉ projekty nie sú. Keď model
      # zvolí iný projekt, controller si dotiahne jeho kontext a zavolá model
      # druhýkrát — inak by musel poznať všetkých 464 kategórií naraz.
      def projects_section(projects, current)
        return [] if projects.blank?

        rows = projects.map do |p|
          desc = p.description.to_s.strip.gsub(/\s+/, ' ')
          line = +"- #{p.name}"
          line << " — #{desc.truncate(110)}" if desc.present?
          line << ' (zde uživatel stojí)' if p.id == current&.id
          line
        end

        ["\n## Projekty, do kterých lze zakládat",
         'Když zadání zjevně patří do jiného projektu, vyber ten jiný — nesnaž se ho ' \
         'vecpat do projektu, ve kterém uživatel stojí.',
         rows.join("\n")]
      end

      # Predchádzajúce otázky modelu a odpovede užívateľa. Vďaka tomu je ďalšie
      # volanie plnohodnotná konverzácia, hoci server sám žiadny stav nedrží —
      # celú históriu posiela klient.
      def conversation_section(history)
        rows = Array(history).filter_map do |row|
          question = row['question'].to_s.strip
          answer   = row['answer'].to_s.strip
          next if question.empty? && answer.empty?

          "- Tvá otázka: #{question}\n  Odpověď uživatele: #{answer.presence || '(bez odpovědi)'}"
        end
        return [] if rows.empty?

        ["\n## Doplňující informace z konverzace",
         'Na tyto otázky už uživatel odpověděl. Znovu se na ně neptej a odpovědi zapracuj.',
         rows.join("\n")]
      end

      def template_section(templates)
        return [] if templates.blank?

        out = ["\n## Šablony popisu podle trackeru"]
        templates.each { |tracker_name, body| out << "\n### #{tracker_name}\n#{body.strip}" }
        out
      end

      # Povinné polia sú tu preto, že bez nich sa úloha neuloží — v Previu je
      # povinný „Project Manager", takže ho model MUSÍ vyplniť.
      # `possible_values_options` vracia dvojice [popis, hodnota]; položku
      # „<< me >>“, ktorú Redmine pridáva pre prihláseného užívateľa, vynechávame,
      # lebo pre model nemá význam.
      def required_fields_section(fields)
        return [] if fields.blank?

        out = ["\n## Povinná pole (musí být vyplněná)"]
        fields.each do |entry|
          line = +"- #{entry[:field].name}"
          values = Array(entry[:values]).map { |label, _v| label.to_s }
                                        .reject { |label| label.start_with?('<<') }
          line << " — povolené hodnoty: #{values.join(', ')}" if values.any?
          out << line
        end
        out
      end

      def similar_section(issues)
        return [] if issues.blank?

        ["\n## Existující otevřené úlohy v tomto projektu (posuď možnou duplicitu)",
         issues.map { |i| "- ##{i.id}: #{i.subject}" }.join("\n")]
      end

      # Spoločná časť oboch promptov — a tým jediné miesto, kde sa rozhoduje,
      # čo opustí Redmine (vrátane GDPR filtrov nižšie).
      def issue_context(issue, settings, description_limit:)
        parts = []
        parts << "# Úloha ##{issue.id}: #{issue.subject}"
        parts << [
          "Stav: #{issue.status&.name}",
          "Priorita: #{issue.priority&.name}",
          "Zadal: #{issue.author&.name}",
          ("Řešitel: #{issue.assigned_to.name}" if issue.assigned_to)
        ].compact.join(' | ')

        description = issue.description.to_s.strip
        if description.present?
          # 0 alebo mínus = neskracovať (celý popis).
          description = description.truncate(description_limit) if description_limit.positive?
          parts << "\n## Popis\n#{description}"
        end

        notes = public_notes(issue)
        parts << "\n## Komentáře (nejnovější poslední)\n" + notes.join("\n\n---\n\n") if notes.any?

        commits = changesets(issue, settings['changeset_limit'].to_i)
        parts << "\n## Související commity\n" + commits.join("\n") if commits.any?

        # Kod z GitLabu (merge request k teto uloze). Vraci prazdno, kdyz je
        # funkce vypnuta, uloha MR nema nebo je GitLab nedostupny.
        parts.concat(CodeContext.issue_section(issue, settings))

        parts
      end

      # GDPR: privátne poznámky sa neposielajú NIKDY — ani keď na ne má
      # užívateľ právo. Externá služba o nich nemá vedieť.
      def public_notes(issue)
        formatted = issue.journals
                         .where(:private_notes => false)
                         .where.not(:notes => [nil, ''])
                         .includes(:user)
                         .order(:id)
                         .map do |j|
                           "**#{j.user&.name} (#{format_date(j.created_on)}):**\n#{j.notes.to_s.strip}"
                         end

        cap_total(formatted)
      rescue StandardError => e
        Rails.logger.warn("[ai_assistant] komentare sa nepodarilo nacitat: #{e.class}: #{e.message}")
        []
      end

      # Pri prekročení stropu zahodíme NAJSTARŠIE komentáre — najnovšie sú pre
      # odpoveď najdôležitejšie.
      def cap_total(formatted)
        total = formatted.sum(&:length)
        return formatted if total <= MAX_NOTES_CHARS

        kept = []
        formatted.reverse_each do |note|
          break if total <= MAX_NOTES_CHARS && kept.any?

          kept.unshift(note)
          total = kept.sum(&:length)
          break if total >= MAX_NOTES_CHARS
        end
        Rails.logger.info("[ai_assistant] prilis dlha diskusia, poslanych " \
                          "#{kept.size} z #{formatted.size} komentarov")
        kept
      end

      # Natívne changesety namiesto hádania podľa slov cez GitLab API.
      # V produkcii je 18 577 väzieb commit↔úloha, takže sú to presné dáta.
      #
      # POZOR: `changeset.short_id` interne volá `repository`, ktorý je v
      # anonymizovanom dumpe nil (tabuľka repositories je prázdna) → NoMethodError.
      # Preto si identifikátor skladáme z `revision`, čo je obyčajný stĺpec a na
      # repozitári nezávisí. Vďaka tomu commity fungujú aj v lokálnom klone.
      def changesets(issue, limit)
        return [] if limit.to_i <= 0

        issue.changesets
             .includes(:user)
             .order(:committed_on => :desc)
             .limit(limit.to_i)
             .map do |c|
               author = c.user&.name.presence || c.committer.to_s.sub(/\s*<.*>\z/, '')
               "- #{short_revision(c)} (#{format_date(c.committed_on)}, #{author}): " \
                 "#{c.comments.to_s.lines.first.to_s.strip}"
             end
      rescue StandardError => e
        # Nezlyhať kvôli commitom — návrh sa dá spraviť aj bez nich. Ale ani to
        # nezamlčať, inak by sa chyba nedala nikdy odhaliť.
        Rails.logger.warn("[ai_assistant] commity sa nepodarilo nacitat: #{e.class}: #{e.message}")
        []
      end

      def short_revision(changeset)
        rev = changeset.revision.to_s
        # Git/Mercurial hash skrátime, číselné revízie (SVN) necháme celé.
        rev.match?(/\A[0-9a-f]{12,}\z/i) ? rev[0, 8] : rev
      end

      def format_date(time)
        time&.strftime('%Y-%m-%d').to_s
      end
    end
  end
end
