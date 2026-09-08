# Sonda: prečo sa pri zadaní "POS tables return HTTP 500 on load 0709" nezobrazia duplicity.
# Púšťa REÁLNE volania Gemini (preklad kľúčových slov + hlavný návrh), takže berie
# z hodinového limitu. Nič neukládá.
#
#   bin/rails runner -e production - < extra/dup_probe.rb

SUBJECT = ENV['SUBJ'].presence || 'POS tables return HTTP 500 on load 0709'
HOME    = ENV['HOME_PROJECT'].presence || 'POS app'

u = User.find_by(login: 'martin_kopac') || User.active.where(admin: true).first
User.current = u
puts "user=#{u.login} (id=#{u.id})"

s     = RedmineAiAssistant.settings
input = { subject: SUBJECT, description: '', history: [] }
puts "zadanie: #{SUBJECT.inspect}"
puts "translate_keywords=#{s['draft_translate_keywords'].inspect} limit=#{s['draft_similar_limit'].inspect}"

client = RedmineAiAssistant::GeminiClient.new(RedmineAiAssistant::KeyStore.api_key)

# --- 1. preklad kľúčových slov (to isté, čo robí controller) -----------------
kw_system = 'Jsi překladač klíčových slov pro hledání v Redmine. ' \
            'Odpovídáš výhradně JSON podle schématu.'
kw_prompt = RedmineAiAssistant::ContextBuilder.search_keywords_prompt(input)
kw_raw    = client.complete_json(kw_system, kw_prompt,
                                 RedmineAiAssistant::IssueDraft::KEYWORDS_SCHEMA,
                                 max_tokens: 4_096)
translated = Array(kw_raw['keywords']).map(&:to_s)
puts "\n--- 1. PREKLAD KLUCOVYCH SLOV ---"
puts "model vratil: #{translated.inspect}"
norm = RedmineAiAssistant::IssueDraft.send(:normalize_keywords, translated)
puts "po normalizacii (>=4 znaky, max 8): #{norm.inspect}"
orig = RedmineAiAssistant::IssueDraft.send(:keywords, input)
puts "fallback z originalu:               #{orig.inspect}"
used = RedmineAiAssistant::IssueDraft.send(:search_tokens, input, translated)
puts "REALNE POUZITE tokeny:              #{used.inspect}"

# --- 2. kandidáti s tými tokenmi -------------------------------------------
home = Project.find_by(name: HOME) || Project.first
lim  = s['draft_similar_limit'].to_i
cands = RedmineAiAssistant::IssueDraft.send(:similar_issues, home, input, lim, translated)
puts "\n--- 2. KANDIDATI (home projekt = #{home.name}) ---"
puts "pocet: #{cands.size}"
cands.first(10).each_with_index { |i, n| puts "  #{n + 1}. ##{i.id} [#{i.project.name}] #{i.subject}" }
puts "  56482 medzi kandidatmi: #{cands.any? { |i| i.id == 56482 } ? 'ANO' : 'NIE'}"

# --- 3. hlavný návrh: čo model vráti v similar_issues -----------------------
opts   = RedmineAiAssistant::IssueDraft.options(home, input, s, translated)
puts "\n--- 3. HLAVNY NAVRH ---"
puts "opts[:similar].size=#{opts[:similar].size}  → similar_issues je v scheme: " \
     "#{RedmineAiAssistant::IssueDraft.schema(opts)[:properties].key?('similar_issues')}"

sys    = RedmineAiAssistant.system_prompt_for(u, 'draft_system_prompt')
prompt = RedmineAiAssistant::ContextBuilder.issue_draft_prompt(home, input, opts)
raw    = client.complete_json(sys, prompt,
                              RedmineAiAssistant::IssueDraft.schema(opts),
                              max_tokens: s['draft_max_tokens'].to_i)
puts "model project=#{raw['project'].inspect}"
puts "model similar_issues RAW=#{raw['similar_issues'].inspect}"
draft = RedmineAiAssistant::IssueDraft.resolve(raw, opts)
puts "po resolve: project_id=#{draft[:project_id].inspect} " \
     "(#{Project.find_by(id: draft[:project_id])&.name})"
puts "po resolve similar_issues=#{draft[:similar_issues].inspect}"
puts "kluc :similar_issues v drafte prítomný: #{draft.key?(:similar_issues)}"

# --- 4. čo by sa stalo pri prepnutí projektu (druhé volanie) ---------------
chosen = Project.find_by(id: draft[:project_id])
if chosen && chosen.id != home.id
  puts "\n--- 4. PREPNUTIE PROJEKTU #{home.name} → #{chosen.name} (druhe volanie) ---"
  opts2 = RedmineAiAssistant::IssueDraft.options(chosen, input, s, translated)
  puts "opts2[:similar].size=#{opts2[:similar].size}"
  raw2  = client.complete_json(sys,
                               RedmineAiAssistant::ContextBuilder.issue_draft_prompt(chosen, input, opts2),
                               RedmineAiAssistant::IssueDraft.schema(opts2),
                               max_tokens: s['draft_max_tokens'].to_i)
  puts "2. volanie similar_issues RAW=#{raw2['similar_issues'].inspect}"
  draft2 = RedmineAiAssistant::IssueDraft.resolve(raw2, opts2)
  puts "2. volanie po resolve similar_issues=#{draft2[:similar_issues].inspect}"
else
  puts "\n--- 4. bez prepnutia projektu (model zvolil #{chosen&.name.inspect}) ---"
end
