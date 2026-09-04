# frozen_string_literal: true

# Zhrnutie sa má zobraziť v jazyku, ktorý má človek nastavený v My account.
#
# Samotná zmena `DEFAULT_SUMMARY_PROMPT` na to nestačí: prompt je nastavenie
# a v tejto inštancii je v DB ULOŽENÝ (prepísaný na anglickú verziu), takže
# `DEFAULTS.merge(stored)` vždy vyhrá uložená hodnota s natvrdo napísaným
# jazykom. Preto sa uložený text upraví tu.
#
# Zasahuje sa minimálne a len tam, kde je jasné čo: „in English" → „in {{LANG}}"
# (resp. české varianty). Keď sa nič z toho v texte nenájde, prompt sa NEMENÍ
# a do logu ide upozornenie — vlastný text admina neprepisujeme naslepo.
class SummaryPromptLanguage < ActiveRecord::Migration[5.2]
  KEY = 'summary_system_prompt'

  # Poradie je dôležité: dlhšie a konkrétnejšie tvary najprv.
  SUBSTITUTIONS = [
    ['in English', 'in {{LANG}}'],
    ['v angličtině', 'v jazyce {{LANG}}'],
    ['anglicky', 'v jazyce {{LANG}}'],
    ['v češtině', 'v jazyce {{LANG}}'],
    ['česky', 'v jazyce {{LANG}}']
  ].freeze

  # Doplnok pre prompty, ktoré názvy sekcií diktujú v konkrétnom jazyku —
  # bez toho by nadpisy zostali anglické aj v maďarskom zhrnutí.
  HEADINGS_NOTE = 'Write the section headings in {{LANG}} as well.'

  def up
    settings = Setting.plugin_redmine_ai_assistant
    return if settings.blank?

    stored = settings.to_h[KEY].to_s
    return if stored.blank?

    if stored.include?('{{LANG}}')
      say 'summary_system_prompt uz {{LANG}} obsahuje, nemenim'
      return
    end

    hit = SUBSTITUTIONS.detect { |from, _to| stored.include?(from) }
    if hit.nil?
      say 'POZOR: v summary_system_prompt sa nenasla zmienka o jazyku. ' \
          'Prompt zostava nezmeneny — doplnte do neho {{LANG}} rucne, ' \
          'inak sa zhrnutie nebude riadit jazykom pouzivatela.'
      return
    end

    updated = stored.sub(hit[0], hit[1])
    updated = "#{updated.rstrip}\n#{HEADINGS_NOTE}\n" unless updated.include?(HEADINGS_NOTE)

    Setting.plugin_redmine_ai_assistant = settings.to_h.merge(KEY => updated)
    say "summary_system_prompt: '#{hit[0]}' -> '#{hit[1]}'"
  end

  # Späť sa dá len to, čo vieme jednoznačne: {{LANG}} → English (pôvodný stav
  # tejto inštancie). Ak by tam bol iný jazyk, admin si ho prepíše sám.
  def down
    settings = Setting.plugin_redmine_ai_assistant
    return if settings.blank?

    stored = settings.to_h[KEY].to_s
    return unless stored.include?('{{LANG}}')

    reverted = stored.sub('in {{LANG}}', 'in English')
                     .sub('v jazyce {{LANG}}', 'česky')
                     .gsub("#{HEADINGS_NOTE}\n", '')
                     .gsub(HEADINGS_NOTE, '')
    Setting.plugin_redmine_ai_assistant = settings.to_h.merge(KEY => reverted.rstrip + "\n")
  end
end
