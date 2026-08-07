# frozen_string_literal: true

class IndexCaddyTrackDomainAuthorization < ActiveRecord::Migration[7.1]

  def change
    add_index :domains, :name
    add_index :track_domains, [:domain_id, :name]
  end

end
