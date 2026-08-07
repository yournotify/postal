#!/usr/bin/env bash
set -euo pipefail

config_file="${POSTAL_CADDY_CONFIG_FILE:-/opt/postal/config/Caddyfile}"
caddy_container="${POSTAL_CADDY_CONTAINER:-postal-caddy}"
web_container="${POSTAL_WEB_CONTAINER:-postal-web-1}"
dry_run="${POSTAL_ON_DEMAND_DRY_RUN:-0}"
ask_endpoint="http://localhost:5000/health/caddy/track-domain/allow"
begin_marker="# BEGIN MANAGED POSTAL TRACK DOMAINS"
end_marker="# END MANAGED POSTAL TRACK DOMAINS"

working_config=$(mktemp)
next_config=$(mktemp)
all_hosts=$(mktemp)
authorized_hosts=$(mktemp)

cleanup() {
  rm -f "${working_config}" "${next_config}" "${all_hosts}" "${authorized_hosts}"
}
trap cleanup EXIT

for command_name in awk chmod cp curl docker grep install mktemp; do
  command -v "${command_name}" >/dev/null
done
docker inspect "${web_container}" "${caddy_container}" >/dev/null
test -f "${config_file}"

runner_prefix="cd /opt/postal/app && bundle exec rails runner"
docker exec "${web_container}" sh -lc \
  "${runner_prefix} 'TrackDomain.includes(:domain).order(:id).each { |track_domain| puts track_domain.full_name.downcase }'" \
  | grep -E '^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$' \
  | sort -u > "${all_hosts}"

docker exec "${web_container}" sh -lc \
  "${runner_prefix} 'TrackDomain.caddy_authorized.includes(:domain).order(:id).each { |track_domain| puts track_domain.full_name.downcase }'" \
  | grep -E '^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$' \
  | sort -u > "${authorized_hosts}"

default_track_host=$(docker exec "${web_container}" sh -lc \
  "${runner_prefix} 'puts Postal::Config.dns.track_domain.to_s.downcase'")
if ! grep -Eq '^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$' <<<"${default_track_host}"; then
  echo "Postal dns.track_domain is not a valid hostname" >&2
  exit 1
fi

first_authorized_host=$(head -n 1 "${authorized_hosts}")
if [[ -z "${first_authorized_host}" ]]; then
  echo "At least one authorized Postal tracking domain is required before migration" >&2
  exit 1
fi
authorized_status=$(curl --silent --output /dev/null --write-out '%{http_code}' \
  --get --data-urlencode "domain=${first_authorized_host}" "${ask_endpoint}")
denied_status=$(curl --silent --output /dev/null --write-out '%{http_code}' \
  --get --data-urlencode "domain=postal-on-demand-denied.invalid" "${ask_endpoint}")
if [[ "${authorized_status}" != "204" || "${denied_status}" != "404" ]]; then
  echo "Postal authorization endpoint is not ready (allowed=${authorized_status}, denied=${denied_status})" >&2
  exit 1
fi

# Remove the superseded generated-host block, if present.
awk -v begin="${begin_marker}" -v end="${end_marker}" '
  $0 == begin { managed = 1; next }
  $0 == end { managed = 0; next }
  !managed { print }
' "${config_file}" > "${working_config}"

# Remove explicit customer tracking sites. Core/default tracking hosts and the
# on-demand catch-all remain static. Abort on unknown tracking proxy blocks so a
# live hostname can never disappear silently during migration.
awk -v hosts_file="${all_hosts}" -v default_host="${default_track_host}" '
  BEGIN {
    while ((getline host < hosts_file) > 0) known[host] = 1
    close(hosts_file)
  }
  function brace_delta(line, copy, opens, closes) {
    copy = line
    opens = gsub(/\{/, "", copy)
    copy = line
    closes = gsub(/\}/, "", copy)
    return opens - closes
  }
  function emit_block(labels, count, host, remove) {
    if (block !~ /X-Postal-Track-Host/) {
      printf "%s", block
      return
    }
    labels = header
    sub(/[[:space:]]*\{.*/, "", labels)
    gsub(/^[[:space:]]+|[[:space:]]+$/, "", labels)
    if (labels == ":443" || labels == "https://") {
      printf "%s", block
      return
    }
    count = split(labels, sites, ",")
    remove = count > 0
    for (i = 1; i <= count; i++) {
      host = sites[i]
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", host)
      if (host == default_host) {
        remove = 0
      } else if (!(host in known)) {
        print "Unknown static tracking host; refusing migration: " host > "/dev/stderr"
        exit 42
      }
    }
    if (!remove) printf "%s", block
  }
  !capturing {
    if ($0 ~ /\{/) {
      capturing = 1
      header = $0
      block = $0 ORS
      depth = brace_delta($0)
      if (depth == 0) {
        emit_block()
        capturing = 0
        block = ""
      }
    } else {
      print
    }
    next
  }
  capturing {
    block = block $0 ORS
    depth += brace_delta($0)
    if (depth == 0) {
      emit_block()
      capturing = 0
      block = ""
    }
  }
  END {
    if (capturing) {
      print "Unbalanced Caddyfile braces; refusing migration" > "/dev/stderr"
      exit 43
    }
  }
' "${working_config}" > "${next_config}"
mv "${next_config}" "${working_config}"
next_config=$(mktemp)

ask_count=$(grep -Ec '^[[:space:]]*ask[[:space:]]+' "${working_config}" || true)
first_content=$(awk 'NF { print; exit }' "${working_config}")
if [[ "${first_content}" == "{" ]]; then
  if [[ "${ask_count}" -ne 1 ]]; then
    echo "Existing global Caddy block must contain exactly one ask directive" >&2
    exit 1
  fi
  awk -v endpoint="${ask_endpoint}" '
    /^[[:space:]]*ask[[:space:]]+/ {
      match($0, /^[[:space:]]*/)
      print substr($0, RSTART, RLENGTH) "ask " endpoint
      next
    }
    { print }
  ' "${working_config}" > "${next_config}"
else
  if [[ "${ask_count}" -ne 0 ]]; then
    echo "Caddy ask directive exists outside a global options block" >&2
    exit 1
  fi
  {
    cat <<EOF
{
  on_demand_tls {
    ask ${ask_endpoint}
  }
}

EOF
    cat "${working_config}"
  } > "${next_config}"
fi
mv "${next_config}" "${working_config}"
next_config=$(mktemp)

if ! grep -Eq '^(:443|https://)[[:space:]]*\{' "${working_config}"; then
  cat >> "${working_config}" <<'EOF'

:443 {
  tls {
    on_demand
  }
  reverse_proxy 127.0.0.1:5000 {
    header_up Host {host}
    header_up X-Real-IP {remote_host}
    header_up X-Forwarded-For {remote_host}
    header_up X-Forwarded-Proto {scheme}
    header_up X-Postal-Track-Host "1"
  }
}
EOF
fi

if [[ "${dry_run}" == "1" ]]; then
  cat "${working_config}"
  exit 0
fi

backup_file="${config_file}.before-postal-on-demand.$(date -u +%Y%m%dT%H%M%SZ)"
install -m 0644 "${config_file}" "${backup_file}"
cp "${working_config}" "${config_file}"
chmod 0644 "${config_file}"
if ! docker exec "${caddy_container}" caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile; then
  cp "${backup_file}" "${config_file}"
  chmod 0644 "${config_file}"
  echo "Caddy validation failed; restored ${backup_file}" >&2
  exit 1
fi
if ! docker exec "${caddy_container}" caddy reload --config /etc/caddy/Caddyfile --adapter caddyfile; then
  cp "${backup_file}" "${config_file}"
  chmod 0644 "${config_file}"
  docker exec "${caddy_container}" caddy reload --config /etc/caddy/Caddyfile --adapter caddyfile || true
  echo "Caddy reload failed; restored ${backup_file}" >&2
  exit 1
fi

systemctl disable --now postal-track-host-sync.timer >/dev/null 2>&1 || true
echo "Postal on-demand TLS is active; previous Caddyfile: ${backup_file}"
echo "Authorized tracking domains: $(wc -l < "${authorized_hosts}")"
