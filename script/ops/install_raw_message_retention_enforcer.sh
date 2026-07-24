#!/usr/bin/env bash
set -euo pipefail

config_dir="${POSTAL_CONFIG_DIR:-/opt/postal/config}"
script_dir="${config_dir}/scripts"
source_dir=$(cd "$(dirname "$0")" && pwd)

mkdir -p "${script_dir}"
install -m 0644 "${source_dir}/raw_message_retention_enforcer.rb" \
  "${script_dir}/raw_message_retention_enforcer.rb"

cat > /usr/local/sbin/postal-raw-message-retention <<'SH'
#!/usr/bin/env bash
set -euo pipefail

exec flock -n /run/postal-raw-message-retention.lock bash -c '
container=$(docker ps --format "{{.Names}}" |
  grep -E "${POSTAL_WORKER_CONTAINER_PATTERN:-(^|-)worker-[0-9]+$}" |
  sort -V |
  head -n 1)
if [[ -z "${container}" ]]; then
  echo "No Postal worker container found" >&2
  exit 1
fi
exec docker exec "${container}" bundle exec rails runner \
  /config/scripts/raw_message_retention_enforcer.rb
'
SH
chmod 0755 /usr/local/sbin/postal-raw-message-retention

cat > /etc/systemd/system/postal-raw-message-retention.service <<'UNIT'
[Unit]
Description=Enforce Postal raw-message size retention
After=docker.service
Requires=docker.service

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/postal-raw-message-retention
Nice=5
IOSchedulingClass=best-effort
IOSchedulingPriority=6
UNIT

cat > /etc/systemd/system/postal-raw-message-retention.timer <<'UNIT'
[Unit]
Description=Enforce Postal raw-message size retention hourly

[Timer]
OnCalendar=*-*-* *:10:00
Persistent=true
AccuracySec=1min
Unit=postal-raw-message-retention.service

[Install]
WantedBy=timers.target
UNIT

systemctl daemon-reload
systemctl start postal-raw-message-retention.service
systemctl enable --now postal-raw-message-retention.timer
systemctl status postal-raw-message-retention.service --no-pager --lines=20 || true
systemctl list-timers --all --no-pager | grep postal-raw-message-retention || true
