#!/bin/bash
set -euo pipefail

postal_hostname="${POSTAL_HOSTNAME:-mail.yournotify.net}"
caddy_data_dir="${CADDY_DATA_DIR:-/opt/postal/caddy-data}"
renew_script="${POSTAL_CERT_RENEW_SCRIPT:-/etc/caddy/hooks/renew-postal.sh}"
certificate_dir="${caddy_data_dir}/caddy/certificates/acme-v02.api.letsencrypt.org-directory/${postal_hostname}"
certificate_name="${postal_hostname}.crt"
private_key_name="${postal_hostname}.key"

command -v inotifywait >/dev/null
test -x "${renew_script}"
mkdir -p "${certificate_dir}"

"${renew_script}"
echo "Watching ${certificate_dir}/${certificate_name} for Caddy renewals"

inotifywait -m -e close_write,create,moved_to "${certificate_dir}" |
while read -r _path _action changed_file; do
  if [[ "${changed_file}" == "${certificate_name}" || "${changed_file}" == "${private_key_name}" ]]; then
    sleep 1
    "${renew_script}"
  fi
done
