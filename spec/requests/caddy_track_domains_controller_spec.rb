# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Caddy tracking-domain authorization", type: :request do
  let!(:track_domain) { create(:track_domain) }

  before { host! "localhost" }

  it "allows an eligible hostname without a user session" do
    get "/health/caddy/track-domain/allow", params: { domain: track_domain.full_name }

    expect(response).to have_http_status(:no_content)
    expect(response.body).to be_empty
  end

  it "denies an ineligible hostname without redirecting to login" do
    track_domain.update!(dns_status: "Invalid")

    get "/health/caddy/track-domain/allow", params: { domain: track_domain.full_name }

    expect(response).to have_http_status(:not_found)
    expect(response.body).to be_empty
  end

  it "denies a request without a hostname" do
    get "/health/caddy/track-domain/allow"

    expect(response).to have_http_status(:not_found)
  end
end
