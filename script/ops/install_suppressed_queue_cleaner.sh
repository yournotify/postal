#!/bin/bash
set -euo pipefail

worker_scale="${1:-}"
cleaner_limit="${YN_SUPPRESSED_QUEUE_CLEANER_LIMIT:-2000}"
install_dir="/opt/postal/install"
config_dir="/opt/postal/config"
script_dir="${config_dir}/scripts"
mariadb_container="${POSTAL_MARIADB_CONTAINER:-postal-mariadb}"
compose_project="${POSTAL_COMPOSE_PROJECT:-postal}"

mkdir -p "${script_dir}"
install -m 0644 "$(dirname "$0")/suppressed_queue_cleaner.rb" "${script_dir}/suppressed_queue_cleaner.rb"

MYSQL_PWD=$(awk '/main_db:/{f=1} f&&/password:/{print $2; exit}' "${config_dir}/postal.yml")
export MYSQL_PWD

message_dbs=$(docker exec -e MYSQL_PWD "${mariadb_container}" mariadb -uroot -Nse "SELECT CONCAT('postal-server-', id) FROM postal.servers")
for db_name in ${message_dbs}; do
  docker exec -e MYSQL_PWD "${mariadb_container}" mariadb -uroot -e \
    "CREATE INDEX IF NOT EXISTS yn_suppressions_type_address_keep_until ON \`${db_name}\`.suppressions (type, address, keep_until);"
done

docker exec -e MYSQL_PWD "${mariadb_container}" mariadb -uroot -e \
  "CREATE INDEX IF NOT EXISTS yn_queued_ready_priority ON postal.queued_messages (ip_address_id, locked_by, locked_at, retry_after, priority, id);"

cat > /usr/local/sbin/postal-suppressed-queue-cleaner <<'SH'
#!/bin/bash
set -euo pipefail
exec flock -n /run/postal-suppressed-queue-cleaner.lock bash -c '
container=$(docker ps --format "{{.Names}}" | grep -E "${POSTAL_WORKER_CONTAINER_PATTERN:-(^|-)worker-[0-9]+$}" | sort -V | head -n 1)
if [[ -z "${container}" ]]; then
  echo "No postal worker container found" >&2
  exit 1
fi
exec docker exec -e YN_SUPPRESSED_QUEUE_CLEANER_LIMIT="${YN_SUPPRESSED_QUEUE_CLEANER_LIMIT:-2000}" "$container" bundle exec rails runner /config/scripts/suppressed_queue_cleaner.rb
'
SH
chmod +x /usr/local/sbin/postal-suppressed-queue-cleaner

cat > /etc/systemd/system/postal-suppressed-queue-cleaner.service <<UNIT
[Unit]
Description=Postal suppressed queued message cleaner
After=docker.service
Requires=docker.service

[Service]
Type=oneshot
Environment=YN_SUPPRESSED_QUEUE_CLEANER_LIMIT=${cleaner_limit}
ExecStart=/usr/local/sbin/postal-suppressed-queue-cleaner
Nice=5
IOSchedulingClass=best-effort
IOSchedulingPriority=6
UNIT

cat > /etc/systemd/system/postal-suppressed-queue-cleaner.timer <<'UNIT'
[Unit]
Description=Run Postal suppressed queued message cleaner every minute

[Timer]
OnBootSec=2min
OnUnitActiveSec=1min
AccuracySec=10s
Unit=postal-suppressed-queue-cleaner.service

[Install]
WantedBy=timers.target
UNIT

systemctl daemon-reload
systemctl enable --now postal-suppressed-queue-cleaner.timer

if [[ -n "${worker_scale}" ]]; then
  cd "${install_dir}"
  docker compose -p "${compose_project}" up -d --no-deps --scale "worker=${worker_scale}" worker
  printf '%s\n' "${worker_scale}" > worker-replicas
  mkdir -p hooks
  cat > hooks/post-start <<EOF
#!/bin/bash
set -e
cd ${install_dir}
docker compose -p ${compose_project} up -d --no-deps --scale worker=${worker_scale} worker
EOF
  chmod +x hooks/post-start
fi

systemctl start postal-suppressed-queue-cleaner.service
systemctl status postal-suppressed-queue-cleaner.service --no-pager --lines=20 || true
systemctl list-timers --all --no-pager | grep postal-suppressed || true
