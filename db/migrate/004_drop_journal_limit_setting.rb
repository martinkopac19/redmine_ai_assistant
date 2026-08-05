# frozen_string_literal: true

# Počet komentárov v kontexte sa už nenastavuje — do promptu idú vždy všetky
# verejné komentáre. Uložená hodnota by tam inak zostala ako mŕtve nastavenie.
class DropJournalLimitSetting < ActiveRecord::Migration[7.2]
  def up
    stored = Setting.plugin_redmine_ai_assistant
    return if stored.blank?

    s = stored.to_h
    return unless s.key?('journal_limit')

    say "odstranujem nepouzivane nastavenie 'journal_limit' (bolo #{s['journal_limit']})"
    s.delete('journal_limit')
    Setting.plugin_redmine_ai_assistant = s
  end

  def down
    # Vracať sa nemá čo — nastavenie už neexistuje.
  end
end
