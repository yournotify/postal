#!/bin/bash
set -euo pipefail

postal_hostname="${POSTAL_HOSTNAME:-mail.yournotify.net}"
caddy_data_dir="${CADDY_DATA_DIR:-/opt/postal/caddy-data}"
postal_config_dir="${POSTAL_CONFIG_DIR:-/opt/postal/config}"
postal_smtp_container="${POSTAL_SMTP_CONTAINER:-postal-smtp-1}"
certificate_dir="${caddy_data_dir}/caddy/certificates/acme-v02.api.letsencrypt.org-directory/${postal_hostname}"
source_certificate="${certificate_dir}/${postal_hostname}.crt"
source_private_key="${certificate_dir}/${postal_hostname}.key"
destination_certificate="${postal_config_dir}/smtp.crt"
destination_private_key="${postal_config_dir}/smtp.key"

for source_file in "${source_certificate}" "${source_private_key}"; do
  if [[ ! -s "${source_file}" ]]; then
    echo "Missing Caddy certificate material: ${source_file}" >&2
    exit 1
  fi
done

if cmp -s "${source_certificate}" "${destination_certificate}" &&
   cmp -s "${source_private_key}" "${destination_private_key}"; then
  echo "Postal SMTP certificate is already current"
  exit 0
fi

install -o 999 -g 999 -m 0644 "${source_certificate}" "${destination_certificate}"
install -o 999 -g 999 -m 0640 "${source_private_key}" "${destination_private_key}"
docker restart "${postal_smtp_container}" >/dev/null
echo "Updated the Postal SMTP certificate for ${postal_hostname}"
