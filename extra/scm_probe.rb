# Co z napojenia na GitLab v tejto instancii naozaj funguje.
# Nastavenia aj repozitare prisli s produkcnym dumpom, takze to popisuje PRODUKCIU.
#
#   bin/rails runner -e production - < extra/scm_probe.rb

def yn(v) = v ? 'ANO' : 'NIE'

puts "Redmine #{Redmine::VERSION}"
puts
puts '=== 1. Nastavenia SCM (Administration -> Repositories) ==='
puts "  povolene SCM               : #{Setting.enabled_scm.inspect}"
puts "  autofetch_changesets       : #{Setting.autofetch_changesets.inspect}"
puts "  sys_api_enabled            : #{Setting.sys_api_enabled.inspect}"
puts "  commit_ref_keywords        : #{Setting.commit_ref_keywords.inspect}"
puts "  commit_update_keywords     : #{Setting.commit_update_keywords.inspect}"
puts "  commit_logtime_enabled     : #{Setting.commit_logtime_enabled.inspect}"
puts "  commit_cross_project_ref   : #{Setting.commit_cross_project_ref.inspect}"
puts "  repository_log_display_limit: #{Setting.repository_log_display_limit.inspect}"
puts

puts '=== 2. Repozitare v DB ==='
repos = Repository.all.to_a
puts "  pocet: #{repos.size}"
repos.group_by(&:type).each { |t, r| puts "    #{t}: #{r.size}" }
puts
repos.first(20).each do |r|
  # URL moze obsahovat cestu na serveri - vypisujeme, je to interna informacia
  puts format('  [%-4s] projekt=%-28s identifier=%-18s',
              r.class.name.sub('Repository::', ''), r.project&.name.to_s[0, 28], r.identifier.to_s[0, 18])
  puts format('         url=%s', r.url.to_s)
  puts format('         root_url=%s  lokalne existuje=%s',
              r.root_url.to_s, yn(r.root_url.present? && File.exist?(r.root_url.to_s)))
end
puts

puts '=== 3. Changesety (commity naviazane na ulohy) ==='
puts "  changesetov celkom      : #{Changeset.count}"
puts "  vazieb commit<->uloha   : #{Changeset.joins(:issues).count}"
last = Changeset.order(committed_on: :desc).first
puts "  posledny commit v DB    : #{last&.committed_on} (rev #{last&.revision.to_s[0, 12]})"
puts "  za poslednych 30 dni    : #{Changeset.where('committed_on > ?', 30.days.ago).count}"
puts "  zmien suborov (changes) : #{Change.count}"
puts

puts '=== 4. Menili commity stav uloh? (commit_update_keywords v praxi) ==='
# Journal s autorom = commit uzivatelom a detailom na status je znamka toho,
# ze klucove slovo v commit message naozaj prepisalo stav.
kw = Setting.commit_update_keywords
puts "  nastavene pravidla: #{kw.inspect}"
if kw.is_a?(Array) && kw.any? { |r| r['keywords'].present? }
  puts '  -> zmena stavu cez commit je NASTAVENA'
else
  puts '  -> ziadne pravidlo na zmenu stavu cez commit'
end
puts

puts '=== 5. Pole Merge request (rucne vyplnovany odkaz) ==='
cf = CustomField.find_by(id: 67) || CustomField.find_by(name: 'Merge request')
if cf
  puts "  cf ##{cf.id} #{cf.name.inspect} format=#{cf.field_format}"
  filled = CustomValue.where(custom_field_id: cf.id).where.not(value: [nil, '']).count
  puts "  vyplnene na #{filled} zaznamoch"
else
  puts '  pole Merge request sa nenaslo'
end
puts

puts '=== 6. Dosiahne TENTO server na GitLab? ==='
require 'resolv'
require 'socket'
host = 'gitlab.previo.info'
begin
  ip = Resolv.getaddress(host)
  puts "  DNS #{host} -> #{ip}"
  begin
    Socket.tcp(host, 443, connect_timeout: 6) { |s| s.close }
    puts '  TCP 443: OTVORENE (server na GitLab dosiahne)'
  rescue StandardError => e
    puts "  TCP 443: NEDOSTUPNE (#{e.class}) -> server na GitLab NEDOSIAHNE"
  end
rescue StandardError => e
  puts "  DNS zlyhalo: #{e.class}: #{e.message}"
end
