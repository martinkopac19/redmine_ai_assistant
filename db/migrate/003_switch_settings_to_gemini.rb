# frozen_string_literal: true

# Prechod z Anthropicu na Gemini: v uložených nastaveniach zostávajú hodnoty
# z pôvodnej verzie, a keďže uložené nastavenia prepisujú defaulty, plugin by
# volal Gemini s modelom "claude-opus-5" a dostal 404.
#
# Hodnoty sú tu zámerne zapísané priamo (nie cez konštanty pluginu) — migrácia
# má byť snapshot stavu v čase, keď sa písala.
class SwitchSettingsToGemini < ActiveRecord::Migration[7.2]
  GEMINI_MODEL   = 'gemini-3.6-flash'
  MIN_MAX_TOKENS = 2048

  def up
    stored = Setting.plugin_redmine_ai_assistant
    return if stored.blank?

    s = stored.to_h
    changed = false

    # Model z Anthropicu → Gemini default.
    if s['model'].to_s.match?(/\Aclaude/i)
      say "model '#{s['model']}' -> '#{GEMINI_MODEL}'"
      s['model'] = GEMINI_MODEL
      changed = true
    end

    # 'effort' je parameter Anthropicu, Gemini ho nepozná.
    if s.key?('effort')
      say "odstranujem nepouzivane nastavenie 'effort'"
      s.delete('effort')
      changed = true
    end

    # U modelov s uvažovaním sa limit delí medzi uvažovanie a odpoveď, takže
    # pri nízkej hodnote prichádza prázdna odpoveď s finishReason MAX_TOKENS.
    if s['max_tokens'].to_i.positive? && s['max_tokens'].to_i < MIN_MAX_TOKENS
      say "max_tokens #{s['max_tokens']} -> #{MIN_MAX_TOKENS}"
      s['max_tokens'] = MIN_MAX_TOKENS.to_s
      changed = true
    end

    # Plugin bol zapnutý v čase osobných kľúčov, ktoré už neexistujú. Vypneme ho,
    # aby ho admin vedome zapol až po vložení spoločného kľúča a potvrdení GDPR.
    if s['enabled'].to_s == '1'
      say 'vypinam plugin — admin ho zapne po vlozeni spolocneho Gemini kluca'
      s['enabled'] = '0'
      changed = true
    end

    Setting.plugin_redmine_ai_assistant = s if changed
  end

  def down
    # Späť sa vracať nemá čo — pôvodné hodnoty patrili inému poskytovateľovi.
  end
end
