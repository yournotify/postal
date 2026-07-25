# frozen_string_literal: true

require "rails_helper"

RSpec.describe Postal::MessageDB::Provisioner do
  let(:server) { create(:server) }
  let(:message) { MessageFactory.incoming(server) }
  let(:database) { server.message_db }

  describe "#remove_messages" do
    it "removes temporary link analytics with expired message metadata" do
      destination = "https://example.com/retained-redirect"
      token = Postal::TrackingLink.encode(destination, server_token: server.token)
      database.update(:messages, { timestamp: 2.days.ago.to_f }, where: { id: message.id })
      database.insert(:links, {
        message_id: message.id,
        token: Postal::TrackingLink.fingerprint(token),
        hash: Digest::SHA1.hexdigest(destination),
        url: destination,
        timestamp: 2.days.ago.to_f
      })

      expect do
        database.provisioner.remove_messages(1)
      end.to change { database.select(:links).size }.from(1).to(0)

      expect(database.select(:messages, where: { id: message.id })).to be_empty
      expect(Postal::TrackingLink.decode(token, server_token: server.token)).to eq destination
    end
  end
end
