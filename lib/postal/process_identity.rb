# frozen_string_literal: true

require "socket"
require "securerandom"

module Postal
  module ProcessIdentity
    # Host-networked containers can share both hostname and namespace PID.
    # A boot identifier prevents separate workers acquiring the same role.
    def process_name
      @process_name ||= "host:#{Socket.gethostname} pid:#{Process.pid} boot:#{SecureRandom.uuid}"
    end
  end
end
