# frozen_string_literal: true

require Rails.root.join("lib/postal/tracking_link")

# Tracking links must never silently fall back to untracked URLs because a
# production keyring was omitted. Validate the permanent key material before
# accepting SMTP, worker, or web traffic.
Postal::TrackingLink.keyring
