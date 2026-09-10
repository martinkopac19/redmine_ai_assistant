# Kontrola pred demom: co je na tejto instancii naozaj zapnute.
#   bin/rails runner -e production - < extra/demo_readiness.rb

def yn(v) = v ? 'ANO' : 'NIE'

puts "Redmine #{Redmine::VERSION}"
puts "app_title=#{Setting.app_title.inspect}  ui_theme=#{Setting.ui_theme.inspect}"
puts "default_language=#{Setting.default_language.inspect}"
puts "reakcie (lajky) zapnute: #{yn(Setting.reactions_enabled?)}" if Setting.respond_to?(:reactions_enabled?)
puts "text_formatting=#{Setting.text_formatting.inspect}"
puts "self_registration=#{Setting.self_registration.inspect}"
puts

puts '--- pluginy ---'
Redmine::Plugin.all.sort_by { |p| p.id.to_s }.each do |p|
  puts format('  %-32s %-8s', p.id, p.version)
end
puts

puts '--- vypinace vlastnych pluginov ---'
checks = {
  'redmine_ai_assistant' => %w[enabled draft_enabled plan_enabled code_context_enabled],
  'redmine_rich_editor'  => %w[enabled],
  'redmine_notify_field_users' => %w[enabled],
  'redmine_notify_reactions'   => %w[enabled],
  'redmine_done_on_close'      => %w[enabled],
  'redmine_big_picture'        => %w[hidden],
  'redmine_remind_me'          => %w[enabled]
}
checks.each do |plugin, keys|
  s = Setting.send(:"plugin_#{plugin}") rescue nil
  next puts "  #{plugin}: (nema nastavenia)" if s.nil?

  vals = keys.map { |k| "#{k}=#{s[k].inspect}" }.join('  ')
  puts "  #{plugin}: #{vals}"
end
puts

puts '--- AI Assistant: je pouzitelny? ---'
if defined?(RedmineAiAssistant)
  puts "  Gemini kluc ulozeny : #{yn(RedmineAiAssistant::KeyStore.present?)}"
  puts "  GitLab token ulozeny: #{yn(RedmineAiAssistant::KeyStore.present?(:gitlab_token))}"
  puts "  usable?             : #{yn(RedmineAiAssistant.usable?)}"
  puts "  plan_usable?        : #{yn(RedmineAiAssistant.plan_usable?)}"
  puts "  model               : #{RedmineAiAssistant.setting('model')}"
end
puts

puts '--- Remind me: cron ---'
if defined?(RemindMeReminder)
  puts "  pripomienok celkom: #{RemindMeReminder.count}  (odoslanych: #{RemindMeReminder.where.not(sent_at: nil).count})"
end
puts

puts '--- data ---'
puts "  uloh: #{Issue.count}  projektov: #{Project.count}  aktivnych userov: #{User.active.count}"
puts "  lajkov v DB: #{defined?(Reaction) ? Reaction.count : 'trieda Reaction neexistuje'}"
tpl = defined?(::GlobalIssueTemplate) ? ::GlobalIssueTemplate.where(enabled: true).count : 'plugin chyba'
puts "  sablon popisu (globalnych, zapnutych): #{tpl}"
