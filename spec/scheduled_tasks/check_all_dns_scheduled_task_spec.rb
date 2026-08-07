# frozen_string_literal: true

require "rails_helper"

RSpec.describe CheckAllDNSScheduledTask do
  subject(:task) { described_class.new(logger: Logger.new(nil)) }

  describe ".next_run_after" do
    it "schedules the next tracking DNS refresh in five minutes" do
      expect(described_class.next_run_after).to be_within(1.second).of(5.minutes.from_now)
    end
  end

  describe "#call" do
    it "rechecks tracking domains whose DNS result is at least five minutes old" do
      stale = create(:track_domain, dns_checked_at: 6.minutes.ago)
      create(:track_domain, dns_checked_at: 4.minutes.ago)
      checked_ids = []
      allow_any_instance_of(TrackDomain).to receive(:check_dns) do |track_domain|
        checked_ids << track_domain.id
      end

      task.call

      expect(checked_ids).to contain_exactly(stale.id)
    end
  end
end
