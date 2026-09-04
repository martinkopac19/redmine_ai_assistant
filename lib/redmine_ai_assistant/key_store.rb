# frozen_string_literal: true

module RedmineAiAssistant
  # Uloženie tajomstiev pluginu: Gemini API kľúč a GitLab token.
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
    # Gemini kľúč sa volá `api_key` z čias, keď bol jediný. Premenovať by
    # znamenalo migrovať uloženú šifru, čo nemá dostatočný dôvod.
    SETTING_KEY  = 'api_key'
    SETTING_HINT = 'api_key_hint'
    CLEAR_PARAM  = 'api_key_clear'

    GITLAB_KEY = 'gitlab_token'

    SECRETS = [SETTING_KEY, GITLAB_KEY].freeze

    class << self
      # Dešifrované tajomstvo na použitie pri volaní API. Nikdy nepatrí do view.
      def secret(name = SETTING_KEY)
        Credentials.decrypt(RedmineAiAssistant.setting(name))
      end

      # Historický názov — používa ho gemini_client aj selftest.
      def api_key
        secret(SETTING_KEY)
      end

      def present?(name = SETTING_KEY)
        RedmineAiAssistant.setting(name).to_s.present?
      end

      # Na zobrazenie v administrácii: "…a1b2". Nikdy celé tajomstvo.
      def hint(name = SETTING_KEY)
        RedmineAiAssistant.setting(hint_key(name)).to_s
      end

      def hint_key(name)
        "#{name}_hint"
      end

      def clear_param(name)
        "#{name}_clear"
      end

      # Volané z patchu SettingsController pred uložením nastavení.
      #   * zaškrtnuté "zmazať"  → tajomstvo sa zmaže
      #   * vyplnené pole        → nové sa zašifruje
      #   * prázdne pole         → existujúce zostáva
      def merge_into_params!(settings_params)
        SECRETS.each { |name| merge_one!(settings_params, name) }
        settings_params
      end

      private

      def merge_one!(settings_params, name)
        hint_name = hint_key(name)
        clear_name = clear_param(name)

        # Pole vo formulári vôbec byť nemusí — vtedy sa uložená hodnota nesmie
        # prepísať prázdnym reťazcom.
        submitted_given = settings_params.key?(name)
        clear = settings_params[clear_name].to_s == '1'
        settings_params.delete(clear_name)
        return settings_params unless submitted_given || clear

        submitted = settings_params[name].to_s

        if clear
          settings_params[name] = ''
          settings_params[hint_name] = ''
        elsif submitted.strip.present?
          settings_params[name] = Credentials.encrypt(submitted.strip)
          settings_params[hint_name] = Credentials.hint(submitted.strip)
        else
          settings_params[name] = RedmineAiAssistant.setting(name).to_s
          settings_params[hint_name] = hint(name)
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
