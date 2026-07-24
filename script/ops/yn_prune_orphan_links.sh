#!/usr/bin/env bash
set -euo pipefail

database_name="${YN_MESSAGE_DB_NAME:?Set YN_MESSAGE_DB_NAME to a postal-server-N database}"
batch_size="${YN_LINK_PRUNE_BATCH_SIZE:-50000}"
max_batches="${YN_LINK_PRUNE_MAX_BATCHES:-10}"
config_file="${POSTAL_CONFIG_FILE:-/opt/postal/config/postal.yml}"
client_config="/tmp/yn-client-${$}.cnf"
database_password=$(awk '/main_db:/,/message_db:/ { if ($1 == "password:") print $2 }' "${config_file}")

[[ "${database_name}" =~ ^postal-server-[0-9]+$ ]] || {
  echo "Invalid YN_MESSAGE_DB_NAME: ${database_name}" >&2
  exit 1
}
[[ "${batch_size}" =~ ^[1-9][0-9]*$ ]] || {
  echo "YN_LINK_PRUNE_BATCH_SIZE must be a positive integer" >&2
  exit 1
}
[[ "${max_batches}" =~ ^[1-9][0-9]*$ ]] || {
  echo "YN_LINK_PRUNE_MAX_BATCHES must be a positive integer" >&2
  exit 1
}

cleanup_client_config() {
  docker exec postal-mariadb rm -f "${client_config}" >/dev/null 2>&1 || true
}
trap cleanup_client_config EXIT

docker exec -i postal-mariadb sh -c "cat > '${client_config}' && chmod 0600 '${client_config}'" <<CNF
[client]
user=root
password=${database_password}
host=127.0.0.1
protocol=tcp
CNF

run_sql() {
  local sql="$1"
  printf "%s\n" "${sql}" |
    docker exec -i postal-mariadb mariadb --defaults-extra-file="${client_config}" -N -B
}

minimum_message_id=$(run_sql "SELECT COALESCE(MIN(id),0) FROM \`${database_name}\`.messages;")
if [[ -z "${minimum_message_id}" || "${minimum_message_id}" == "0" ]]; then
  echo "No retained messages found; refusing to prune links"
  exit 0
fi

total_deleted=0
for ((batch = 1; batch <= max_batches; batch++)); do
  deleted=$(run_sql "DELETE FROM \`${database_name}\`.links WHERE message_id < ${minimum_message_id} ORDER BY message_id LIMIT ${batch_size}; SELECT ROW_COUNT();" | tail -1)
  deleted=${deleted:-0}
  total_deleted=$((total_deleted + deleted))
  echo "batch=${batch} min_message_id=${minimum_message_id} deleted=${deleted} total_deleted=${total_deleted}"
  if [[ "${deleted}" -lt "${batch_size}" ]]; then
    break
  fi
  sleep 1
done
