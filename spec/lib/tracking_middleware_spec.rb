# frozen_string_literal: true

require "rails_helper"
require "rack/test"

RSpec.describe TrackingMiddleware do
  include Rack::Test::Methods

  let(:inner_app) { -> (_env) { [200, {}, ["inner"]] } }
  let(:app) { described_class.new(inner_app) }

  let(:server) { create(:server) }
  let(:message) do
    MessageFactory.incoming(server) do |_msg, mail|
      mail.html_part = Mail::Part.new do
        content_type "text/html; charset=UTF-8"
        body "<html><body>hi</body></html>"
      end
    end
  end

  def track_headers
    { "HTTP_X_POSTAL_TRACK_HOST" => "1" }
  end

  describe "GET /img/:server_token/:message_token (open tracking pixel)" do
    before do
      get "/img/#{server.token}/#{message.token}", {}, track_headers
    end

    it "returns the tracking pixel PNG" do
      expect(last_response.status).to eq 200
      expect(last_response.headers["Content-Type"]).to eq "image/png"
      expect(last_response.body.bytesize).to be > 0
    end

    it "records a load for the message" do
      # Re-fetch the message so loads are read fresh from the DB.
      reloaded = server.message_db.message(message.id)
      expect(reloaded.loads.size).to eq 1
    end
  end

  describe "GET /img/:server_token/:message_token?src=<url> (image proxy)" do
    let(:attacker_url) { "http://internal.example.com/secret" }

    before do
      stub_request(:get, attacker_url).to_return(status: 200, body: "internal-secret")
    end

    it "does not fetch the URL and returns 400" do
      get "/img/#{server.token}/#{message.token}", { src: attacker_url }, track_headers

      expect(last_response.status).to eq 400
      expect(WebMock).not_to have_requested(:get, attacker_url)
    end

    it "does not fetch the URL even when the message token is invalid" do
      get "/img/#{server.token}/nonexistent", { src: attacker_url }, track_headers

      expect(WebMock).not_to have_requested(:get, attacker_url)
    end
  end

  describe "when the track-host header is missing" do
    it "passes the request through to the inner app untouched" do
      get "/img/#{server.token}/#{message.token}"
      expect(last_response.body).to eq "inner"
    end
  end

  describe "GET /:server_token/:encrypted_link (click tracking)" do
    let(:destination) { "https://example.com/products/42?campaign=summer" }
    let(:encrypted_token) { Postal::TrackingLink.encode(destination, server_token: server.token) }

    it "redirects without a database row" do
      get "/#{server.token}/#{encrypted_token}", {}, track_headers

      expect(last_response.status).to eq 307
      expect(last_response.headers["Location"]).to eq destination
    end

    it "records analytics while the message and hot link row exist" do
      message_db = server.message_db
      message_db.insert(:links, {
        message_id: message.id,
        token: Postal::TrackingLink.fingerprint(encrypted_token),
        hash: Digest::SHA1.hexdigest(destination),
        url: destination,
        timestamp: Time.now.to_f
      })

      expect do
        get "/#{server.token}/#{encrypted_token}", {}, track_headers
      end.to change { message_db.select(:clicks).size }.by(1)

      expect(last_response.status).to eq 307
      expect(last_response.headers["Location"]).to eq destination
    end

    it "rejects a modified token" do
      replacement = encrypted_token.end_with?("A") ? "B" : "A"
      get "/#{server.token}/#{encrypted_token[0...-1]}#{replacement}", {}, track_headers

      expect(last_response.status).to eq 404
    end

    it "rejects an old random database token" do
      get "/#{server.token}/K8qP2mN7xL4vR9tB", {}, track_headers

      expect(last_response.status).to eq 404
    end
  end
end
