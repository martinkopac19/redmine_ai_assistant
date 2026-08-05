# frozen_string_literal: true

class AiAssistantController < ApplicationController
  before_action :require_login
  before_action :require_usable

  # POZOR: `render_error` NEPREPISOVAŤ — Redmine core má vlastné
  # ApplicationController#render_error(arg) s jedným argumentom a používa ho
  # v obsluhe CSRF a chybových stránok. Prepísanie ho rozbije (500 namiesto 422).
  # Preto sa naša metóda volá render_json_error.

  def suggest
    issue = find_available_issue
    return if issue.nil?

    # Cache per (úloha, posledný komentár) — opakované kliknutie bez zmeny
    # v úlohe negeneruje nový (platený) request.
    cache_key = ['ai_assistant_suggest', issue.id, issue.journals.maximum(:id).to_i,
                 User.current.id].join(':')
    cached = Rails.cache.read(cache_key)
    return render(:json => { :text => cached, :cached => true }) if cached.present?

    return if rate_limited?

    text = client.complete(
      RedmineAiAssistant.system_prompt_for(User.current),
      RedmineAiAssistant::ContextBuilder.suggestion_prompt(issue, RedmineAiAssistant.settings)
    )
    Rails.cache.write(cache_key, text, :expires_in => 1.hour)
    render :json => { :text => text }
  rescue RedmineAiAssistant::GeminiClient::Error => e
    render_ai_error(e)
  end

  private

  def require_usable
    return if RedmineAiAssistant.usable?

    key = RedmineAiAssistant.enabled? ? :'ai_assistant.error_no_key' : :'ai_assistant.error_disabled'
    render_json_error(key, :forbidden)
  end

  def client
    RedmineAiAssistant::GeminiClient.new(RedmineAiAssistant::KeyStore.api_key)
  end

  def find_available_issue
    issue = Issue.find_by(:id => params[:issue_id])
    unless RedmineAiAssistant.available_for?(issue)
      render_json_error(:'ai_assistant.error_unavailable', :forbidden)
      return nil
    end
    issue
  end

  def rate_limited?
    return false if RedmineAiAssistant.consume_rate_limit!(User.current)

    render_json_error(:'ai_assistant.error_rate_limited', :too_many_requests)
    true
  end

  # Chyby idú ako HTTP 4xx/5xx s JSON správou — nikdy ako text návrhu s HTTP 200.
  # Správa od Gemini sa do odpovede NEDÁVA (mohla by obsahovať detaily o kľúči
  # alebo projekte); ide len do logu.
  def render_ai_error(error)
    key, status =
      case error
      when RedmineAiAssistant::GeminiClient::AuthError      then [:error_invalid_key, :unprocessable_entity]
      when RedmineAiAssistant::GeminiClient::RateLimitError then [:error_provider_rate_limited, :too_many_requests]
      when RedmineAiAssistant::GeminiClient::BlockedError   then [:error_blocked, :unprocessable_entity]
      when RedmineAiAssistant::GeminiClient::TruncatedError then [:error_truncated, :unprocessable_entity]
      else
        case error.message.to_s
        when 'timeout'     then [:error_timeout, :gateway_timeout]
        when 'unreachable' then [:error_unreachable, :bad_gateway]
        else [:error_generic, :bad_gateway]
        end
      end

    Rails.logger.error("[ai_assistant] #{error.class}: #{error.message}")
    render :json => { :error => l(:"ai_assistant.#{key}") }, :status => status
  end

  def render_json_error(key, status)
    render :json => { :error => l(key) }, :status => status
  end
end
