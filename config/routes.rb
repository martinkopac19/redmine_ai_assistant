# frozen_string_literal: true

RedmineApp::Application.routes.draw do
  # Kľúč sa nastavuje výhradne v administrácii (konfigurácia pluginu), preto tu
  # už žiadna routa na jeho ukladanie nie je.
  post 'ai_assistant/suggest', to: 'ai_assistant#suggest', as: 'ai_assistant_suggest'
  post 'ai_assistant/summary', to: 'ai_assistant#summary', as: 'ai_assistant_summary'
  # Predvyplnenie novej úlohy. Nie je scopované pod projekt — projekt prichádza
  # v tele requestu a overuje sa právom :add_issues.
  post 'ai_assistant/draft_issue', to: 'ai_assistant#draft_issue', as: 'ai_assistant_draft_issue'
  # Režim plánu. Vlastná routa, nie parameter na draft_issue: odpoveď má iný
  # formát, a `with_ai_guard` renderuje čokoľvek, čo v cache nájde — pri
  # zdieľanom cache prefixe by klient dostal payload druhého formátu.
  post 'ai_assistant/plan_issues', to: 'ai_assistant#plan_issues', as: 'ai_assistant_plan_issues'
  # Číselník projektov pre okno. Žiadne volanie AI, teda ani hodinový limit.
  post 'ai_assistant/plan_context', to: 'ai_assistant#plan_context', as: 'ai_assistant_plan_context'
end
