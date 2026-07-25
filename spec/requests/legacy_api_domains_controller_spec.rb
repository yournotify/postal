# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Legacy domain API", type: :request do
  let(:server) { create(:server) }
  let(:credential) { create(:credential, server: server, type: "API") }
  let(:headers) { { "X-Server-API-Key" => credential.key } }

  def response_data
    JSON.parse(response.body).fetch("data")
  end

  describe "domains created through Postal's UI owner association" do
    let!(:domain) do
      server.domains.create!(
        name: "existing.example.com",
        verification_method: "DNS",
        verified_at: Time.current
      )
    end

    it "queries the existing domain without requiring the legacy server_id column" do
      expect(domain.server_id).to be_nil

      post "/api/v1/domains/query", params: { name: domain.name }, headers: headers

      expect(response).to have_http_status(:ok)
      expect(JSON.parse(response.body).fetch("status")).to eq("success")
      expect(response_data).to include(
        "id" => domain.id,
        "name" => domain.name,
        "server_id" => server.id
      )
    end

    it "returns the existing domain from create instead of attempting a duplicate" do
      expect do
        post "/api/v1/domains/create", params: { name: domain.name }, headers: headers
      end.not_to change(Domain, :count)

      expect(response).to have_http_status(:ok)
      expect(response_data.fetch("id")).to eq(domain.id)
    end

    it "checks the existing domain" do
      allow_any_instance_of(Domain).to receive(:check_dns).and_return(true)

      post "/api/v1/domains/check", params: { name: domain.name }, headers: headers

      expect(response).to have_http_status(:ok)
      expect(response_data.fetch("id")).to eq(domain.id)
    end

    it "deletes the existing domain" do
      expect do
        post "/api/v1/domains/delete", params: { name: domain.name }, headers: headers
      end.to change { server.domains.where(id: domain.id).count }.from(1).to(0)

      expect(response).to have_http_status(:ok)
      expect(JSON.parse(response.body).fetch("status")).to eq("success")
    end
  end

  describe "domains created through the API" do
    it "creates an owner-scoped domain that subsequent API calls can query" do
      post "/api/v1/domains/create", params: { name: "created.example.com" }, headers: headers

      expect(response).to have_http_status(:ok)
      expect(JSON.parse(response.body).fetch("status")).to eq("success")
      domain = server.domains.find_by!(name: "created.example.com")
      expect(domain.owner).to eq(server)

      post "/api/v1/domains/query", params: { name: domain.name }, headers: headers

      expect(response).to have_http_status(:ok)
      expect(response_data).to include(
        "id" => domain.id,
        "name" => domain.name,
        "server_id" => server.id
      )
    end
  end
end
