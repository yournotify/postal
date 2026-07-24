#!/usr/bin/env bash
set -euo pipefail

source_dir=$(cd "$(dirname "$0")" && pwd)
web_container="${POSTAL_WEB_CONTAINER:-}"
caddy_container="${POSTAL_CADDY_CONTAINER:-postal-caddy}"
config_file="${POSTAL_CADDY_CONFIG_FILE:-/opt/postal/config/Caddyfile}"

if [[ -z "${web_container}" ]]; then
  mapfile -t web_containers < <(docker ps --format '{{.Names}}' | grep -E '(^|-)web-[0-9]+$' || true)
  if [[ "${#web_containers[@]}" -ne 1 ]]; then
    echo "Set POSTAL_WEB_CONTAINER to the Postal web container name" >&2
    exit 1
  fi
  web_container="${web_containers[0]}"
fi
docker inspect "${web_container}" "${caddy_container}" >/dev/null
test -f "${config_file}"

begin_marker="# BEGIN MANAGED POSTAL TRACK DOMAINS"
end_marker="# END MANAGED POSTAL TRACK DOMAINS"
if ! grep -Fxq "${begin_marker}" "${config_file}"; then
  {
    printf '\n%s\n' "${begin_marker}"
    printf '%s\n' "${end_marker}"
  } >> "${config_file}"
fi

install -m 0755 "${source_dir}/sync_postal_track_hosts.sh" /usr/local/sbin/postal-track-host-sync
cat > /etc/default/postal-track-host-sync <<EOF
POSTAL_WEB_CONTAINER=${web_container}
POSTAL_CADDY_CONTAINER=${caddy_container}
POSTAL_CADDY_CONFIG_FILE=${config_file}
EOF
chmod 0644 /etc/default/postal-track-host-sync

cat > /etc/systemd/system/postal-track-host-sync.service <<'UNIT'
[Unit]
Description=Synchronize Postal tracking domains into Caddy
After=docker.service network-online.target
Requires=docker.service

[Service]
Type=oneshot
EnvironmentFile=/etc/default/postal-track-host-sync
ExecStart=/usr/local/sbin/postal-track-host-sync

UNIT

cat > /etc/systemd/system/postal-track-host-sync.timer <<'UNIT'
[Unit]
Description=Synchronize Postal tracking domains into Caddy every minute

[Timer]
OnBootSec=30s
OnUnitActiveSec=60s
AccuracySec=10s
Unit=postal-track-host-sync.service

[Install]
WantedBy=timers.target
UNIT

systemctl daemon-reload
systemctl start postal-track-host-sync.service
systemctl enable --now postal-track-host-sync.timer
systemctl status postal-track-host-sync.service --no-pager --lines=20 || true
