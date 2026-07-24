#!/usr/bin/env bash
set -euo pipefail

postal_hostname="${1:-${POSTAL_HOSTNAME:-}}"
postal_smtp_container="${2:-${POSTAL_SMTP_CONTAINER:-}}"
source_dir=$(cd "$(dirname "$0")" && pwd)

if [[ -z "${postal_hostname}" ]]; then
  echo "Usage: $0 POSTAL_HOSTNAME [POSTAL_SMTP_CONTAINER]" >&2
  exit 1
fi
if [[ ! "${postal_hostname}" =~ ^[a-z0-9.-]+$ ]]; then
  echo "Invalid Postal hostname: ${postal_hostname}" >&2
  exit 1
fi
if [[ -z "${postal_smtp_container}" ]]; then
  mapfile -t smtp_containers < <(docker ps --format '{{.Names}}' | grep -E '(^|-)smtp-[0-9]+$' || true)
  if [[ "${#smtp_containers[@]}" -ne 1 ]]; then
    echo "Could not uniquely detect the SMTP container; pass it as the second argument" >&2
    exit 1
  fi
  postal_smtp_container="${smtp_containers[0]}"
fi

command -v docker >/dev/null
command -v inotifywait >/dev/null
command -v openssl >/dev/null
docker inspect "${postal_smtp_container}" >/dev/null

install -d -m 0755 /etc/caddy/hooks
install -m 0755 "${source_dir}/renew_postal_certificate.sh" /etc/caddy/hooks/renew-postal.sh
install -m 0755 "${source_dir}/watch_postal_certificate.sh" /etc/caddy/hooks/watcher.sh

cat > /etc/default/postal-caddy-cert-sync <<EOF
POSTAL_HOSTNAME=${postal_hostname}
POSTAL_SMTP_CONTAINER=${postal_smtp_container}
POSTAL_CERT_RENEW_SCRIPT=/etc/caddy/hooks/renew-postal.sh
EOF
chmod 0644 /etc/default/postal-caddy-cert-sync

cat > /etc/systemd/system/caddy-cert-watcher.service <<'UNIT'
[Unit]
Description=Synchronize Caddy TLS certificate into Postal SMTP
After=docker.service network-online.target
Requires=docker.service

[Service]
Type=simple
EnvironmentFile=/etc/default/postal-caddy-cert-sync
ExecStart=/etc/caddy/hooks/watcher.sh
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
UNIT

systemctl daemon-reload
/usr/bin/env bash -a -c 'source /etc/default/postal-caddy-cert-sync; exec /etc/caddy/hooks/renew-postal.sh'
systemctl enable --now caddy-cert-watcher.service
systemctl status caddy-cert-watcher.service --no-pager --lines=20
