# frozen_string_literal: true

# Prechod z osobných kľúčov na jeden spoločný firemný kľúč: osobné kľúče už
# neexistujú, spoločný je (šifrovaný) v nastaveniach pluginu.
class DropAiCredentials < ActiveRecord::Migration[7.2]
  def up
    drop_table :ai_credentials, :if_exists => true
  end

  def down
    create_table :ai_credentials do |t|
      t.references :user, :null => false,
                   :index => { :unique => true, :name => 'index_ai_credentials_on_user' }
      t.text :encrypted_api_key, :null => false
      t.string :key_hint, :limit => 8
      t.timestamps
    end
  end
end
