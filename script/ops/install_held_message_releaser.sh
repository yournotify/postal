#!/bin/bash
set -euo pipefail

releaser_limit="${YN_HELD_MESSAGE_RELEASER_LIMIT:-100}"
min_age_minutes="${YN_HELD_MESSAGE_RELEASER_MIN_AGE_MINUTES:-15}"
allow_pattern="${YN_HELD_MESSAGE_RELEASER_ALLOW_PATTERN:-send limit}"
config_dir="/opt/postal/config"
script_dir="${config_dir}/scripts"

mkdir -p "${script_dir}"
install -m 0644 "$(dirname "$0")/held_message_releaser.rb" "${script_dir}/held_message_releaser.rb"

MYSQL_PWD=$(awk '/main_db:/{f=1} f&&/password:/{print $2; exit}' "${config_dir}/postal.yml")
export MYSQL_PWD

docker exec -e MYSQL_PWD postal-mariadb mariadb -uroot -e \
  "CREATE INDEX IF NOT EXISTS yn_queued_server_message ON postal.queued_messages (server_id, message_id);"

cat > /usr/local/sbin/postal-held-message-releaser <<'SH'
#!/bin/bash
set -euo pipefail
exec flock -n /run/postal-held-message-releaser.lock bash -c '
container=$(docker ps --format "{{.Names}}" | grep -E "^postal-worker-" | sort -V | head -n 1)
if [[ -z "${container}" ]]; then
  echo "No postal worker container found" >&2
  exit 1
fi
exec docker exec \
  -e YN_HELD_MESSAGE_RELEASER_LIMIT="${YN_HELD_MESSAGE_RELEASER_LIMIT:-100}" \
  -e YN_HELD_MESSAGE_RELEASER_MIN_AGE_MINUTES="${YN_HELD_MESSAGE_RELEASER_MIN_AGE_MINUTES:-15}" \
  -e YN_HELD_MESSAGE_RELEASER_ALLOW_PATTERN="${YN_HELD_MESSAGE_RELEASER_ALLOW_PATTERN:-send limit}" \
  "$container" bundle exec rails runner /config/scripts/held_message_releaser.rb
'
SH
chmod +x /usr/local/sbin/postal-held-message-releaser

cat > /etc/systemd/system/postal-held-message-releaser.service <<UNIT
[Unit]
Description=Postal retryable held message releaser
After=docker.service
Requires=docker.service

[Service]
Type=oneshot
Environment=YN_HELD_MESSAGE_RELEASER_LIMIT=${releaser_limit}
Environment=YN_HELD_MESSAGE_RELEASER_MIN_AGE_MINUTES=${min_age_minutes}
Environment=YN_HELD_MESSAGE_RELEASER_ALLOW_PATTERN=${allow_pattern}
ExecStart=/usr/local/sbin/postal-held-message-releaser
Nice=5
IOSchedulingClass=best-effort
IOSchedulingPriority=6
UNIT

cat > /etc/systemd/system/postal-held-message-releaser.timer <<'UNIT'
[Unit]
Description=Run Postal retryable held message releaser every five minutes

[Timer]
OnBootSec=5min
OnUnitActiveSec=5min
AccuracySec=30s
Unit=postal-held-message-releaser.service

[Install]
WantedBy=timers.target
UNIT

systemctl daemon-reload
systemctl enable --now postal-held-message-releaser.timer
systemctl start postal-held-message-releaser.service
systemctl status postal-held-message-releaser.service --no-pager --lines=20 || true
systemctl list-timers --all --no-pager | grep postal-held || true