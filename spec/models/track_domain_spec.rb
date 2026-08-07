# frozen_string_literal: true

require "rails_helper"

RSpec.describe TrackDomain do
  subject(:track_domain) { build(:track_domain) }

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
