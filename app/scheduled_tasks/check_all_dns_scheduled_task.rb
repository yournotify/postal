# frozen_string_literal: true

class CheckAllDNSScheduledTask < ApplicationScheduledTask

  def call
    Domain.where.not(dns_checked_at: nil).where("dns_checked_at <= ?", 1.hour.ago).each do |domain|
      logger.info "checking DNS for domain: #{domain.name}"
      domain.check_dns(:auto)
    end

    TrackDomain.where("dns_checked_at IS NULL OR dns_checked_at <= ?", 5.minutes.ago).includes(:domain).each do |domain|
      logger.info "checking DNS for track domain: #{domain.full_name}"
      domain.check_dns
    end
  end

  def self.next_run_after
    5.minutes.from_now
  end

end
