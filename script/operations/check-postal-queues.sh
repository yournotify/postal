#!/bin/sh
set -eu
worker=$(docker ps --filter label=com.docker.compose.service=worker --format '{{.Names}}' | sort | head -1)
test -n "$worker"
docker exec -i "$worker" bin/rails runner - < /opt/postal/operations/queue_health.rb
