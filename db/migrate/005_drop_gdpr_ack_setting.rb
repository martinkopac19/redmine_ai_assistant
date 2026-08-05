# frozen_string_literal: true

# Checkbox "Potvrdenie o odosielaní dát" bol na žiadosť zrušený — plugin sa
# riadi len prepínačom "Zapnúť" a prítomnosťou kľúča. Uložená hodnota by tam
# inak zostala ako mŕtve nastavenie (a pri gdpr_ack = '0' by mýlila).
class DropGdprAckSetting < ActiveRecord::Migration[7.2]
  def up
    stored = Setting.plugin_redmine_ai_assistant
    return if stored.blank?

    s = stored.to_h
    return unless s.key?('gdpr_ack')

    say "odstranujem zrusene nastavenie 'gdpr_ack' (bolo #{s['gdpr_ack']})"
    s.delete('gdpr_ack')
    Setting.plugin_redmine_ai_assistant = s
  end

  def down
    # Vracať sa nemá čo — nastavenie už neexistuje.
  end
end
