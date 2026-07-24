#!/usr/bin/env bash
set -euo pipefail

config_file="${POSTAL_CADDY_CONFIG_FILE:-/opt/postal/config/Caddyfile}"
caddy_container="${POSTAL_CADDY_CONTAINER:-postal-caddy}"
web_container="${POSTAL_WEB_CONTAINER:-postal-web-1}"
allow_url="${CADDY_TRACK_ALLOW_URL:-}"
dry_run="${POSTAL_TRACK_SYNC_DRY_RUN:-0}"
begin_marker="# BEGIN MANAGED POSTAL TRACK DOMAINS"
end_marker="# END MANAGED POSTAL TRACK DOMAINS"
temporary_config=$(mktemp)
managed_block=$(mktemp)
backup_config=$(mktemp)

cleanup() {
  rm -f "${temporary_config}" "${managed_block}" "${backup_config}"
}
trap cleanup EXIT

for command_name in docker curl awk; do
  command -v "${command_name}" >/dev/null
done
for required_value in "${config_file}" "${caddy_container}" "${web_container}"; do
  [[ -n "${required_value}" ]] || exit 1
done
grep -Fxq "${begin_marker}" "${config_file}" || {
  echo "Missing marker in ${config_file}: ${begin_marker}" >&2
  exit 1
}
grep -Fxq "${end_marker}" "${config_file}" || {
  echo "Missing marker in ${config_file}: ${end_marker}" >&2
  exit 1
}

mapfile -t track_hosts < <(
  docker exec "${web_container}" sh -lc \
    "cd /opt/postal/app && bundle exec rails runner 'TrackDomain.ok.includes(:domain).order(:id).each { |track_domain| puts track_domain.full_name.downcase }'" |
    grep -E '^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$' |
    sort -u
)

host_is_statically_configured() {
  local target="$1"
  awk -v begin="${begin_marker}" -v end="${end_marker}" -v target="${target}" '
    $0 == begin { managed = 1; next }
    $0 == end { managed = 0; next }
    managed { next }
    /\{/ {
      line = $0
      sub(/\{.*/, "", line)
      count = split(line, hosts, ",")
      for (i = 1; i <= count; i++) {
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", hosts[i])
        if (hosts[i] == target) found = 1
      }
    }
    END { exit(found ? 0 : 1) }
  ' "${config_file}"
}

approved_hosts=()
for host in "${track_hosts[@]}"; do
  if host_is_statically_configured "${host}"; then
    echo "Leaving ${host} in the static Caddy configuration"
    continue
  fi
  if [[ -n "${allow_url}" ]]; then
    status=$(curl --get --silent --show-error --output /dev/null --write-out '%{http_code}' \
      --data-urlencode "domain=${host}" "${allow_url}" || true)
    if [[ "${status}" != "200" ]]; then
      echo "Skipping ${host}: authorization endpoint returned HTTP ${status}" >&2
      continue
    fi
  fi
  approved_hosts+=("${host}")
done

{
  echo "${begin_marker}"
  echo "# Generated from Postal DNS-verified tracking domains. Do not edit this block."
  for host in "${approved_hosts[@]}"; do
    cat <<EOF
${host} {
  reverse_proxy 127.0.0.1:5000 {
    header_up Host {host}
    header_up X-Real-IP {remote_host}
    header_up X-Forwarded-For {remote_host}
    header_up X-Forwarded-Proto {scheme}
  }
}

EOF
  done
  echo "${end_marker}"
} > "${managed_block}"

awk -v begin="${begin_marker}" -v end="${end_marker}" -v block="${managed_block}" '
  $0 == begin {
    while ((getline line < block) > 0) print line
    close(block)
    replacing = 1
    next
  }
  $0 == end {
    replacing = 0
    next
  }
  !replacing { print }
' "${config_file}" > "${temporary_config}"

if [[ "${dry_run}" == "1" ]]; then
  cat "${temporary_config}"
  exit 0
fi

if cmp -s "${temporary_config}" "${config_file}"; then
  echo "Caddy tracking hosts are already current (${#approved_hosts[@]} managed)"
  exit 0
fi

cp -p "${config_file}" "${backup_config}"
install -m 0644 "${temporary_config}" "${config_file}"
if ! docker exec "${caddy_container}" caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile; then
  cp -p "${backup_config}" "${config_file}"
  echo "Caddy validation failed; restored the previous configuration" >&2
  exit 1
fi
if ! docker exec "${caddy_container}" caddy reload --config /etc/caddy/Caddyfile --adapter caddyfile; then
  cp -p "${backup_config}" "${config_file}"
  docker exec "${caddy_container}" caddy reload --config /etc/caddy/Caddyfile --adapter caddyfile || true
  echo "Caddy reload failed; restored the previous configuration" >&2
  exit 1
fi
echo "Updated Caddy with ${#approved_hosts[@]} DNS-verified Postal tracking domains"
