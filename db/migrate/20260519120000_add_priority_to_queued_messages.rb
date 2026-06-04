# frozen_string_literal: true

class AddPriorityToQueuedMessages < ActiveRecord::Migration[7.0]
  def change
    add_column :queued_messages, :priority, :integer, default: 0, null: false
    add_index :queued_messages, [:priority, :id], name: "index_queued_messages_on_priority_and_id"
  end
end