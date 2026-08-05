# frozen_string_literal: true

class CreateAiCredentials < ActiveRecord::Migration[7.2]
  def change
    create_table :ai_credentials do |t|
      # Pomenovaný index — PostgreSQL má limit na dĺžku názvu identifikátora.
      t.references :user, :null => false,
                   :index => { :unique => true, :name => 'index_ai_credentials_on_user' }
      t.text :encrypted_api_key, :null => false
      t.string :key_hint, :limit => 8
      t.timestamps
    end
  end
end
