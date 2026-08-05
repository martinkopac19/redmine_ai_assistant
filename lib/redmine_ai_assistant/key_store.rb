# frozen_string_literal: true

module RedmineAiAssistant
  # Uloženie spoločného Gemini API kľúča.
  #
  # PROBLÉM, ktorý toto rieši: `password_field_tag 'x', @settings['key']` vykreslí
  # <input type="password" value="SKUTOCNY_KLUC"> — type="password" maskuje kľúč
  # len vizuálne, v HTML je celý a vidno ho cez Inspect element aj View source.
  #
  # RIEŠENIE: pole na kľúč sa renderuje VŽDY prázdne, kľúč sa do prehliadača
  # neposiela nikdy. V nastaveniach je uložený šifrovane a zobrazuje sa len
  # posledné 4 znaky. Aby prázdne pole kľúč nezmazalo, dopĺňame pri ukladaní
  # existujúcu hodnotu (viď SettingsControllerPatch).
  module KeyStore
    SETTING_KEY  = 'api_key'
    SETTING_HINT = 'api_key_hint'
    CLEAR_PARAM  = 'api_key_clear'

    class << self
      # Dešifrovaný kľúč na použitie pri volaní API. Nikdy nepatrí do view.
      def api_key
        Credentials.decrypt(RedmineAiAssistant.setting(SETTING_KEY))
      end

      def present?
        RedmineAiAssistant.setting(SETTING_KEY).to_s.present?
      end

      # Na zobrazenie v administrácii: "…a1b2". Nikdy celý kľúč.
      def hint
        RedmineAiAssistant.setting(SETTING_HINT).to_s
      end

      # Volané z patchu SettingsController pred uložením nastavení.
      #   * zaškrtnuté "zmazať"  → kľúč sa zmaže
      #   * vyplnené pole        → nový kľúč sa zašifruje
      #   * prázdne pole         → existujúci kľúč zostáva
      def merge_into_params!(settings_params)
        submitted = settings_params[SETTING_KEY].to_s
        clear     = settings_params[CLEAR_PARAM].to_s == '1'
        settings_params.delete(CLEAR_PARAM)

        if clear
          settings_params[SETTING_KEY]  = ''
          settings_params[SETTING_HINT] = ''
        elsif submitted.strip.present?
          settings_params[SETTING_KEY]  = Credentials.encrypt(submitted.strip)
          settings_params[SETTING_HINT] = Credentials.hint(submitted.strip)
        else
          settings_params[SETTING_KEY]  = RedmineAiAssistant.setting(SETTING_KEY).to_s
          settings_params[SETTING_HINT] = hint
        end

        settings_params
      end
    end
  end

  # Prázdne pole na kľúč nesmie uložený kľúč zmazať, a nový kľúč sa musí
  # zašifrovať ešte pred zápisom do nastavení. Redmine na to nemá hook, preto
  # prepend na SettingsController#plugin — obmedzený výhradne na tento plugin.
  module SettingsControllerPatch
    PLUGIN_ID = 'redmine_ai_assistant'

    def plugin
      if request.post? && params[:id].to_s == PLUGIN_ID && params[:settings].present?
        KeyStore.merge_into_params!(params[:settings])
      end
      super
    end
  end
end
