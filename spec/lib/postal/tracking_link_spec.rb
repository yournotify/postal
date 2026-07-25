# frozen_string_literal: true

require "rails_helper"

RSpec.describe Postal::TrackingLink do
  let(:destination) { "https://example.com/a/path?one=1&two=hello#section" }
  let(:server_token) { "server-token" }

  it "round-trips an authenticated destination without database state" do
    token = described_class.encode(destination, server_token: server_token)

    expect(token).to match(/\A[A-Za-z0-9_-]+\z/)
    expect(described_class.decode(token, server_token: server_token)).to eq destination
  end

  it "binds the encrypted destination to its Postal server token" do
    token = described_class.encode(destination, server_token: server_token)

    expect do
      described_class.decode(token, server_token: "another-server")
    end.to raise_error(described_class::InvalidToken)
  end

  it "rejects non-HTTP destinations" do
    expect do
      described_class.encode("javascript:alert(1)", server_token: server_token)
    end.to raise_error(described_class::InvalidToken)
  end

  it "creates a stable lookup fingerprint without exposing the destination" do
    token = described_class.encode(destination, server_token: server_token)
    fingerprint = described_class.fingerprint(token)

    expect(fingerprint).to eq described_class.fingerprint(token)
    expect(fingerprint).not_to include("example.com")
  end
end
