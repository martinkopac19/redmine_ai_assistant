# frozen_string_literal: true

RedmineApp::Application.routes.draw do
  # Kľúč sa nastavuje výhradne v administrácii (konfigurácia pluginu), preto tu
  # už žiadna routa na jeho ukladanie nie je.
  post 'ai_assistant/suggest', to: 'ai_assistant#suggest', as: 'ai_assistant_suggest'
  post 'ai_assistant/summary', to: 'ai_assistant#summary', as: 'ai_assistant_summary'
end
