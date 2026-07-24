#!/usr/bin/env bash
set -euo pipefail

usage_percent=$(df --output=pcent / | tail -1 | tr -dc "0-9")
log_limit="${YN_DOCKER_LOG_LIMIT:-100M}"

find /var/lib/docker/containers -name "*-json.log" -type f -size "+${log_limit}" -exec truncate -s 0 {} +
journalctl --vacuum-size="${YN_JOURNAL_LIMIT:-300M}" >/dev/null || true

if [[ "${usage_percent}" -ge "${YN_IMAGE_PRUNE_THRESHOLD:-80}" ]]; then
  docker image prune -af >/dev/null || true
fi

if [[ "${usage_percent}" -ge "${YN_SYSTEM_LOG_TRUNCATE_THRESHOLD:-88}" ]]; then
  truncate -s 0 /var/log/btmp /var/log/btmp.1 2>/dev/null || true
fi

df -h /
