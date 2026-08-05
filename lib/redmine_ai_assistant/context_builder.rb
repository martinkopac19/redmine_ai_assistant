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
          parts << "\n## Popis\n#{description.truncate(settings['description_limit'].to_i)}"
        end

        notes = public_notes(issue)
        parts << "\n## Komentáře (nejnovější poslední)\n" + notes.join("\n\n---\n\n") if notes.any?

        commits = changesets(issue, settings['changeset_limit'].to_i)
        parts << "\n## Související commity\n" + commits.join("\n") if commits.any?

        parts << "\n## Zadání\nNapiš stručnou a věcnou odpověď na poslední komentář " \
                 'nebo na zmínku o tobě. Odpověď musí být v češtině a připravená ' \
                 'k přímému vložení do Redmine.'

        parts.join("\n")
      end

      private

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
