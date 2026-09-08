# Testovacie data pre `dup_cdp_test.mjs`: jeden docasny uzivatel.
#
# Je zamerne ADMIN a ma jazyk `sk` — presne tak to ma Martin, ktory bug hlasil,
# a jeden beh testu tak overi aj hladanie duplicit naprieč projektami (admin vidi
# vsetko) aj to, ze tlacidlo je prelozene.
#
#   bin/rails runner -e production - < extra/dup_fixture.rb setup
#   bin/rails runner -e production - < extra/dup_fixture.rb teardown
#
# Argument sa cez `runner -` neprenasa, preto ho ber z ENV:
#   MODE=setup|teardown

LOGIN = 're_dup_admin'
PASS  = 'DocasneHesloNaTest-2026'
MODE  = ENV['MODE'].presence || 'setup'

User.current = User.active.where(admin: true).first

case MODE
when 'setup'
  u = User.find_by(login: LOGIN)
  if u.nil?
    u = User.new(login: LOGIN, firstname: 'Docasny', lastname: 'DupTester',
                 # Klon ma whitelist domen (`email_domains_allowed`), takze
                 # `example.invalid` neprejde. Ziadny mail sa v teste neposiela.
                 mail: "#{LOGIN}-docasny@previo.cz", language: 'sk', admin: true)
    u.password = u.password_confirmation = PASS
    u.must_change_passwd = false
    raise "usera sa nepodarilo vytvorit: #{u.errors.full_messages.join(', ')}" unless u.save

    puts "vytvoreny user #{u.login} (id=#{u.id})"
  else
    u.update_columns(language: 'sk', admin: true, status: User::STATUS_ACTIVE)
    puts "user #{u.login} (id=#{u.id}) uz existoval — jazyk a admin dorovnane"
  end

  puts "login=#{LOGIN} pass=#{PASS} language=#{u.reload.language} admin=#{u.admin?}"

  # Projekty pre test: kde sa stoji (home) a kam ma AI prepnut (POS app).
  pos = Project.find_by(name: 'POS app')
  puts "POS app id=#{pos&.id}"
  home = Project.active.where.not(id: pos&.id).sorted.detect { |p| p.trackers.any? }
  puts "home projekt (stoji sa v nom) = #{home&.name} id=#{home&.id}"
  dup = Issue.find_by(id: 56482)
  puts "duplicita #56482: #{dup ? "#{dup.subject} [#{dup.project.name}] open=#{!dup.closed?}" : 'CHYBA'}"

when 'teardown'
  u = User.find_by(login: LOGIN)
  if u
    # Ulohy sa v teste nezakladaju (Create sa nikdy neklika), takze nie je co osirotit.
    created = Issue.where(author_id: u.id).count
    raise "user ma #{created} zalozenych uloh — teardown by ich osirotil" if created.positive?

    u.destroy
    puts "user #{LOGIN} zmazany"
  else
    puts "user #{LOGIN} neexistuje"
  end
  puts "kontrola: #{User.where(login: LOGIN).count} uzivatelov s tymto loginom"

else
  raise "neznamy MODE=#{MODE.inspect} (setup|teardown)"
end
