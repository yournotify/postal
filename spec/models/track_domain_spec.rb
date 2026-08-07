# frozen_string_literal: true

require "rails_helper"

RSpec.describe TrackDomain do
  subject(:track_domain) { build(:track_domain) }

  describe ".caddy_authorized_for?" do
    let!(:authorized_domain) { create(:track_domain, name: "click") }

    it "authorizes the exact DNS-verified, SSL-enabled hostname" do
      expect(described_class.caddy_authorized_for?(authorized_domain.full_name)).to be(true)
    end

    it "normalizes case, whitespace, and a trailing dot" do
      hostname = "  #{authorized_domain.full_name.upcase}.  "

      expect(described_class.caddy_authorized_for?(hostname)).to be(true)
    end

    it "rejects a domain whose DNS is not verified" do
      authorized_domain.update!(dns_status: "Invalid")

      expect(described_class.caddy_authorized_for?(authorized_domain.full_name)).to be(false)
    end

    it "rejects a domain whose SSL setting is disabled" do
      authorized_domain.update!(ssl_enabled: false)

      expect(described_class.caddy_authorized_for?(authorized_domain.full_name)).to be(false)
    end

    it "rejects a suspended server" do
      authorized_domain.server.update!(suspended_at: Time.current)

      expect(described_class.caddy_authorized_for?(authorized_domain.full_name)).to be(false)
    end

    it "rejects a suspended organization" do
      authorized_domain.server.organization.update!(suspended_at: Time.current)

      expect(described_class.caddy_authorized_for?(authorized_domain.full_name)).to be(false)
    end

    it "rejects a deleted server" do
      authorized_domain.server.update!(deleted_at: Time.current)

      expect(described_class.caddy_authorized_for?(authorized_domain.full_name)).to be(false)
    end

    it "rejects malformed and unknown hostnames" do
      expect(described_class.caddy_authorized_for?("https://#{authorized_domain.full_name}")).to be(false)
      expect(described_class.caddy_authorized_for?("unknown.example.com")).to be(false)
      expect(described_class.caddy_authorized_for?(nil)).to be(false)
    end
  end

  describe "#expected_cname" do
    it "uses the deployment tracking target" do
      allow(Postal::Config.dns).to receive(:track_domain).and_return("track.smtp.example.com")

      expect(track_domain.expected_cname).to eq("track.smtp.example.com")
    end
  end

  describe "name validation" do
    it { is_expected.to allow_value("click").for(:name) }
    it { is_expected.to allow_value("click.smtp").for(:name) }
    it { is_expected.to allow_value("click.mail-east").for(:name) }
    it { is_expected.not_to allow_value(".click").for(:name) }
    it { is_expected.not_to allow_value("click.").for(:name) }
    it { is_expected.not_to allow_value("click..smtp").for(:name) }
    it { is_expected.not_to allow_value("click.-smtp").for(:name) }
    it { is_expected.not_to allow_value("click.smtp-").for(:name) }
  end
end
