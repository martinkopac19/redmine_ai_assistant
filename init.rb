# frozen_string_literal: true

# Redmine AI Assistant (Previo)
# Návrh odpovede a preklad komentárov priamo na detaile úlohy, cez Gemini.
#
# Kľúčové vlastnosti:
#   * JEDEN spoločný Gemini API kľúč, ktorý zadáva výhradne admin v konfigurácii
#     pluginu. Kľúč je šifrovaný a do prehliadača sa NIKDY neposiela — pole je
#     vždy prázdne, zobrazuje sa len posledné 4 znaky. Nedá sa ho teda prečítať
#     ani cez Inspect element.
#   * Komentár vytvára natívny IssuesController#update, takže autor, notifikácie,
#     journal aj práva fungujú bez zmeny.
#   * Preklad pred odoslaním je dvojkrokový a viditeľný — nikdy sa neodošle text,
#     ktorý užívateľ nevidel.
#   * Do Gemini sa NIKDY neposielajú privátne poznámky ani privátne úlohy.
#
# Pozn.: require_relative aj patche sú zámerne tu a nie v to_prepare —
# to_prepare sa v production nespúšťa.
require_relative 'lib/redmine_ai_assistant'
require_relative 'lib/redmine_ai_assistant/credentials'
require_relative 'lib/redmine_ai_assistant/key_store'
require_relative 'lib/redmine_ai_assistant/gemini_client'
require_relative 'lib/redmine_ai_assistant/context_builder'
require_relative 'lib/redmine_ai_assistant/issue_draft'
require_relative 'lib/redmine_ai_assistant/hooks'

Redmine::Plugin.register :redmine_ai_assistant do
  name 'AI Assistant (Previo)'
  author 'Martin Kopáč'
  description 'Gemini-powered reply drafts, issue summaries and new-issue prefill, with one shared admin-managed API key.'
  version '0.5.0'
  url 'https://github.com/martinkopac19/redmine_ai_assistant'
  requires_redmine version_or_higher: '5.0'

  settings :default => RedmineAiAssistant::DEFAULTS.dup,
           :partial => 'settings/ai_assistant'
end

# Prútik v hlavičke, vedľa ikonky osoby. `account_menu` je jediné menu v tej
# oblasti, do ktorého sa dá pridať bez patchu layoutu, a `:before => :my_account`
# ho posadí hneď za meno prihláseného.
#
# Caption sa NEDÁ nahradiť inline SVG — `render_single_menu_node` ju prepúšťa
# cez `h(caption)` (jadrové menu_manager.rb:188), takže by sa vypísala ako text.
# Ikonka preto ide z CSS ako `::before` s data-URI, presne tým istým trikom,
# aký téma previo používa pre ikonku osoby a pre zvonček. Text popisku zostáva
# v DOM pre čítačky obrazovky, len ho CSS vizuálne skryje.
#
# URL je `#`: okno otvára JS, ktorý klik zruší. Bez `preventDefault` by
# prehliadač odskočil na začiatok stránky.
Redmine::MenuManager.map :account_menu do |menu|
  menu.push :ai_issue_creator, '#',
            :caption => :'ai_assistant.button_plan',
            :before  => :my_account,
            :html    => { :class => 'raa-plan-link', 'data-raa' => 'plan' },
            :if      => proc { RedmineAiAssistant.plan_available_anywhere? }
end

# Prázdne pole na kľúč nesmie uložený kľúč zmazať a nový kľúč sa musí zašifrovať
# ešte pred zápisom. Redmine na ukladanie pluginových nastavení hook nemá.
unless SettingsController.included_modules.include?(RedmineAiAssistant::SettingsControllerPatch)
  SettingsController.prepend(RedmineAiAssistant::SettingsControllerPatch)
end
