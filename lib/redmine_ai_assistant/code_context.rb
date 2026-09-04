# frozen_string_literal: true

module RedmineAiAssistant
  # Kód do promptu.
  #
  # Sem chodí ďaleko citlivejší materiál než do zvyšku pluginu, preto sú tu
  # filtre dvakrát: raz podľa cesty k súboru (celý súbor sa vynechá) a raz podľa
  # obsahu riadku (hodnota sa prepíše). Dôvod nie je teoretický — úplne prvý
  # testovací dotaz na hľadanie v kóde vrátil medzi tromi výsledkami cestu
  # `config/secrets/prod/prod.RABBITMQ_URL...php`.
  #
  # Politika Previa (potvrdená 4. 9. 2026) je, že zdrojový kód smie odísť do
  # firemného Gemini. Tajomstvá tým pokryté NIE SÚ — heslo v prompte je heslo
  # v logu poskytovateľa, nech je politika akákoľvek.
  module CodeContext
    # Odkaz na MR v úlohe: `https://gitlab.previo.info/previo/previo2/-/merge_requests/5270`
    # alebo tá istá adresa s `/-/commit/<sha>`. Meranie na produkčných dátach:
    # 8 751 z 8 770 vyplnených hodnôt má presne tento tvar.
    LINK = %r{\Ahttps?://(?<host>[^/\s]+)/(?<project>.+?)/-/(?<kind>merge_requests|commit)/(?<ref>[^/?#\s]+)}i

    # Súbory, ktoré do promptu nesmú ísť NIKDY (bezpečnosť).
    DENY_PATH = Regexp.union(
      %r{(\A|/)\.env}i,
      %r{(\A|/)secrets?(\z|/)}i,
      %r{secret}i,
      %r{credential}i,
      %r{(\A|/)id_(rsa|dsa|ecdsa|ed25519)}i,
      %r{\.(pem|key|p12|pfx|jks|keystore|asc|gpg)\z}i,
      %r{(\A|/)\.(npmrc|netrc|pgpass|htpasswd)\z}i,
      %r{auth\.json\z}i
    ).freeze

    # Súbory, ktoré sa vynechávajú preto, že len žerú miesto (nie bezpečnosť).
    NOISE_PATH = Regexp.union(
      %r{(\A|/)(node_modules|vendor|dist|build|coverage|\.git)/},
      %r{(package-lock\.json|yarn\.lock|composer\.lock|Gemfile\.lock|pnpm-lock\.yaml)\z}i,
      %r{\.min\.(js|css)\z}i,
      %r{\.(png|jpe?g|gif|bmp|ico|webp|svg|pdf|zip|gz|tar|woff2?|ttf|eot|otf|mp4|mp3)\z}i,
      %r{\.(snap|map)\z}i
    ).freeze

    # Priradenie, ktoré vyzerá ako tajomstvo → hodnota sa prepíše. Zámerne
    # necháva kľúč viditeľný: modelu stačí vedieť, že sa tam nastavuje token.
    SECRET_ASSIGNMENT = /
      ((?:api[_-]?key|secret|passwd|password|token|authorization|bearer|
         private[_-]?key|access[_-]?key|client[_-]?secret|dsn)
       [^\n]{0,24}?[:=]\s*['"]?)
      ([^\s'"]{8,})
    /ix.freeze

    PEM_BLOCK = /-----BEGIN [A-Z ]*PRIVATE KEY-----/.freeze
    REDACTED = '[odstraneno-tajemstvi]'

    class << self
      # Sekcia „## Kód" pre existujúcu úlohu (návrh odpovede aj zhrnutie).
      # Vracia pole riadkov, aby sedelo do `issue_context`. Nikdy nevyhodí
      # výnimku: bez kódu je návrh horší, ale stále použiteľný.
      def issue_section(issue, settings)
        return [] unless enabled?(settings)

        client = client(settings)
        return [] unless client&.configured?

        link = mr_link_for(issue)
        return [] if link.nil?

        target = parse_link(link, client.host)
        return [] if target.nil?

        case target[:kind]
        when 'merge_requests' then merge_request_section(client, target, settings)
        when 'commit' then commit_section(client, target, settings)
        else []
        end
      rescue StandardError => e
        warn_only(e, "issue #{issue&.id}")
        []
      end

      # Sekcia pre návrh NOVEJ úlohy. Tam ešte žiadny merge request neexistuje,
      # takže jediné, čo sa dá ponúknuť, je hľadanie v kóde podľa kľúčových slov,
      # ktoré si model vyrobil sám pre hľadanie duplicít.
      def draft_section(project, keywords, settings)
        return [] unless enabled?(settings)

        per_repo = settings['code_search_results'].to_i
        return [] unless per_repo.positive?

        client = client(settings)
        return [] unless client&.configured?

        words = Array(keywords).map(&:to_s).map(&:strip).reject(&:empty?).first(2)
        return [] if words.empty?

        repos = repos_for_project(project, settings)
        return [] if repos.empty?

        hits = search_hits(client, repos, words, per_repo)
        return [] if hits.empty?

        ["\n## Kód v repozitáři (nalezeno podle klíčových slov)",
         'Tohle je jen nález fulltextového hledání, ne důkaz. Použij to k tomu, ' \
         'abys úkol zařadil do správného projektu a popsal ho konkrétněji.',
         hits.join("\n")]
      rescue StandardError => e
        warn_only(e, "draft #{project&.identifier}")
        []
      end

      # --- veci, ktoré potrebuje aj selftest -----------------------------------

      def deny_path?(path)
        p = path.to_s
        p.empty? || DENY_PATH.match?(p)
      end

      def skip_path?(path)
        deny_path?(path) || NOISE_PATH.match?(path.to_s)
      end

      def redact(text)
        return '' if text.nil?

        text.to_s.gsub(SECRET_ASSIGNMENT) { "#{Regexp.last_match(1)}#{REDACTED}" }
      end

      def parse_link(value, expected_host)
        m = LINK.match(value.to_s.strip)
        return nil if m.nil?
        # Pole s odkazom môže vyplniť ktokoľvek. Token smie odísť len na náš GitLab.
        return nil if expected_host.blank? || m[:host].downcase != expected_host.to_s.downcase

        { :project => m[:project], :kind => m[:kind].downcase, :ref => m[:ref] }
      end

      def enabled?(settings)
        settings['code_context_enabled'].to_s == '1'
      end

      def client(settings)
        GitlabClient.new(:base_url => settings['gitlab_url'],
                         :token => KeyStore.secret('gitlab_token'))
      end

      private

      def mr_link_for(issue)
        field = mr_field
        return nil if field.nil? || issue.nil?

        issue.custom_value_for(field)&.value.presence
      end

      # Pole sa hľadá podľa formátu a názvu, nie podľa natvrdo napísaného id:
      # id 67 platí pre produkciu Previa a plugin má byť použiteľný aj inde.
      def mr_field
        @mr_field = nil unless defined?(@mr_field_at) && @mr_field_at.to_i > 5.minutes.ago.to_i
        return @mr_field if @mr_field

        @mr_field_at = Time.now.to_i
        @mr_field = IssueCustomField.where(:field_format => 'link')
                                    .detect { |f| f.name.to_s.match?(/merge\s*request/i) }
      rescue StandardError
        nil
      end

      def merge_request_section(client, target, settings)
        mr = client.merge_request(target[:project], target[:ref])
        parts = ["\n## Merge request !#{mr['iid']} (#{target[:project]})"]
        parts << [
          "Název: #{mr['title']}",
          "Stav: #{mr['state']}",
          "Větev: #{mr['source_branch']} → #{mr['target_branch']}",
          "Autor: #{mr['author'] && mr['author']['name']}"
        ].compact.join(' | ')

        description = mr['description'].to_s.strip
        parts << "Popis MR:\n#{redact(description).truncate(1_500)}" if description.present?

        parts.concat(review_section(client, target))
        parts.concat(diff_section(client.merge_request_changes(target[:project], target[:ref])['changes'],
                                  settings))
        parts
      rescue GitlabClient::Error => e
        # Nedostupný GitLab nesmie zhodiť návrh odpovede — ale ani sa zamlčať,
        # inak by sa nedalo zistiť, že kontext kódu ticho zmizol.
        warn_only(e, "MR #{target[:project]}!#{target[:ref]}")
        []
      end

      def commit_section(client, target, settings)
        info = client.commit(target[:project], target[:ref])
        parts = ["\n## Commit #{target[:ref][0, 8]} (#{target[:project]})"]
        parts << "#{info['title']} — #{info['author_name']}"
        parts.concat(diff_section(client.commit_diff(target[:project], target[:ref]), settings))
        parts
      rescue GitlabClient::Error => e
        warn_only(e, "commit #{target[:project]}@#{target[:ref]}")
        []
      end

      # Pripomienky z code review sú pri návrhu ODPOVEDE často to najcennejšie:
      # v Redmine komentároch sa typicky rieši presne to, čo reviewer napísal do MR.
      # Systémové poznámky (přiřazeno, přejmenováno…) sa vynechávajú.
      def review_section(client, target)
        notes = client.merge_request_discussions(target[:project], target[:ref])
                      .flat_map { |d| Array(d['notes']) }
                      .reject { |n| n['system'] }
                      .map do |n|
                        body = redact(n['body'].to_s.strip).truncate(600)
                        author = n['author'] && n['author']['name']
                        file = n.dig('position', 'new_path')
                        next if body.empty?

                        "- #{author}#{" (#{file})" if file.present?}: #{body}"
                      end.compact
        return [] if notes.empty?

        ["\n### Připomínky z code review", notes.first(30).join("\n")]
      rescue GitlabClient::Error => e
        warn_only(e, "discussions #{target[:project]}!#{target[:ref]}")
        []
      end

      # Diff s rozpočtom. Jeden veľký súbor nesmie zjesť celé miesto, preto
      # okrem celkového stropu platí aj strop na súbor.
      def diff_section(changes, settings)
        rows = Array(changes)
        return [] if rows.empty?

        budget = settings['code_diff_limit'].to_i
        budget = 40_000 unless budget.positive?
        per_file = [budget / 4, 2_000].max

        kept = []
        omitted = []
        used = 0

        rows.each do |change|
          path = change['new_path'].presence || change['old_path'].to_s
          if deny_path?(path)
            omitted << "#{path} (vynecháno bezpečnostním filtrem)"
            next
          end
          if NOISE_PATH.match?(path)
            omitted << "#{path} (vygenerovaný/binární soubor)"
            next
          end

          diff = change['diff'].to_s
          next if diff.strip.empty?
          if PEM_BLOCK.match?(diff)
            omitted << "#{path} (obsahuje privátní klíč)"
            next
          end

          diff = redact(diff)
          room = [budget - used, per_file].min
          if room < 200
            omitted << "#{path} (nevešel se do limitu)"
            next
          end
          if diff.length > room
            diff = "#{diff[0, room]}\n… (zkráceno)"
          end

          used += diff.length
          kept << "#### #{path}\n```diff\n#{diff}\n```"
        end

        parts = []
        parts << "\n### Změny v kódu\n#{kept.join("\n")}" if kept.any?
        parts << "\n### Nezobrazené soubory\n- #{omitted.join("\n- ")}" if omitted.any?
        parts
      end

      # Ktorý GitLab repozitár patrí k tomuto Redmine projektu. Neudržiava sa
      # nikde zoznam — odvodí sa z toho, kam reálne mieria merge requesty úloh
      # v tom projekte. Namerané: pri väčšine projektov je dominantný repozitár
      # na 76–100 %, pár projektov (Channel Manager, Door locks) reálne pracuje
      # v dvoch, preto sa berú dva.
      def repos_for_project(project, settings)
        return [] if project.nil?

        Rails.cache.fetch("ai_assistant/repos/#{project.id}", :expires_in => 12.hours) do
          field = mr_field
          next [] if field.nil?

          host = client(settings).host
          values = CustomValue.where(:customized_type => 'Issue', :custom_field_id => field.id)
                              .where.not(:value => [nil, ''])
                              .where(:customized_id => Issue.where(:project_id => project.id).select(:id))
                              .limit(2_000).pluck(:value)

          counts = Hash.new(0)
          values.each do |v|
            target = parse_link(v, host)
            counts[target[:project]] += 1 if target
          end
          total = counts.values.sum
          next [] if total.zero?

          counts.sort_by { |_repo, n| -n }
                .select { |_repo, n| n * 100 / total >= 15 }
                .first(2).map(&:first)
        end
      rescue StandardError => e
        warn_only(e, "repos for #{project&.identifier}")
        []
      end

      def search_hits(client, repos, words, per_repo)
        seen = {}
        repos.each do |repo|
          words.each do |word|
            begin
              results = client.search_blobs(repo, word, per_repo)
            rescue GitlabClient::Error => e
              warn_only(e, "search #{repo}/#{word}")
              next
            end
            Array(results).each do |hit|
              path = hit['path'].to_s
              next if skip_path?(path)

              key = "#{repo}:#{path}"
              next if seen.key?(key)

              snippet = redact(hit['data'].to_s.strip).truncate(400)
              seen[key] = "- **#{repo}** `#{path}`" \
                          "#{" (řádek #{hit['startline']})" if hit['startline']}" \
                          "#{"\n```\n#{snippet}\n```" unless snippet.empty?}"
            end
          end
        end
        seen.values.first(per_repo * repos.size)
      end

      def warn_only(err, what)
        Rails.logger&.warn("[ai_assistant] kod (#{what}): #{err.class}: #{err.message}")
      end
    end
  end
end
