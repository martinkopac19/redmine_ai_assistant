# frozen_string_literal: true

module RedmineAiAssistant
  # Šifrovanie osobných API kľúčov.
  #
  # Zámerne ActiveSupport::MessageEncryptor a nie Active Record Encryption:
  # AR Encryption vyžaduje nastavené primary_key / deterministic_key /
  # key_derivation_salt, ktoré Redmine nemá, a ich doplnenie by znamenalo
  # editovať mountnutý config/additional_environment.rb a riešiť rotáciu.
  #
  # POZOR: bezpečnosť stojí a padá na secret_key_base. Lokálny docker-compose
  # má slabý REDMINE_SECRET_KEY_BASE — pre lokálny klon je to prijateľné,
  # pre reálne nasadenie musí byť silný a mimo gitu.
  module Credentials
    SALT = 'redmine_ai_assistant/api_key'

    class << self
      def encrypt(plain)
        return nil if plain.blank?

        encryptor.encrypt_and_sign(plain.to_s)
      end

      def decrypt(payload)
        return nil if payload.blank?

        encryptor.decrypt_and_verify(payload)
      rescue ActiveSupport::MessageVerifier::InvalidSignature,
             ActiveSupport::MessageEncryptor::InvalidMessage
        # Zmenený secret_key_base → starý kľúč sa už nedá prečítať.
        nil
      end

      # Posledné 4 znaky na zobrazenie v profile ("…a1b2"). Nikdy nie celý kľúč.
      def hint(plain)
        plain.to_s.strip[-4..].to_s
      end

      private

      def encryptor
        key = ActiveSupport::KeyGenerator.new(Rails.application.secret_key_base)
                                        .generate_key(SALT, 32)
        ActiveSupport::MessageEncryptor.new(key)
      end
    end
  end
end
