# frozen_string_literal: true

require "rails_helper"

RSpec.describe TrackDomain do
  subject(:track_domain) { build(:track_domain) }

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
