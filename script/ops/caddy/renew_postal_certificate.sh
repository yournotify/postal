#!/bin/bash
set -euo pipefail

postal_hostname="${POSTAL_HOSTNAME:-mail.yournotify.net}"
caddy_data_dir="${CADDY_DATA_DIR:-/opt/postal/caddy-data}"
postal_config_dir="${POSTAL_CONFIG_DIR:-/opt/postal/config}"
postal_smtp_container="${POSTAL_SMTP_CONTAINER:-postal-smtp-1}"
minimum_validity_seconds="${POSTAL_CERT_MIN_VALIDITY_SECONDS:-86400}"
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

openssl x509 -in "${source_certificate}" -noout -checkend "${minimum_validity_seconds}" >/dev/null || {
  echo "Caddy certificate expires in less than ${minimum_validity_seconds} seconds" >&2
  exit 1
}
openssl x509 -in "${source_certificate}" -noout -checkhost "${postal_hostname}" >/dev/null || {
  echo "Caddy certificate does not cover ${postal_hostname}" >&2
  exit 1
}

certificate_public_key=$(openssl x509 -in "${source_certificate}" -pubkey -noout | openssl sha256)
private_public_key=$(openssl pkey -in "${source_private_key}" -pubout 2>/dev/null | openssl sha256)
if [[ "${certificate_public_key}" != "${private_public_key}" ]]; then
  echo "Caddy certificate and private key do not match" >&2
  exit 1
fi

if cmp -s "${source_certificate}" "${destination_certificate}" &&
   cmp -s "${source_private_key}" "${destination_private_key}"; then
  echo "Postal SMTP certificate is already current"
  exit 0
fi

install -o 999 -g 999 -m 0644 "${source_certificate}" "${destination_certificate}"
install -o 999 -g 999 -m 0640 "${source_private_key}" "${destination_private_key}"
openssl x509 -in "${destination_certificate}" -noout -checkhost "${postal_hostname}" >/dev/null
docker restart "${postal_smtp_container}" >/dev/null
echo "Updated the Postal SMTP certificate for ${postal_hostname}"
