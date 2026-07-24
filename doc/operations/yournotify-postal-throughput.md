# Yournotify Postal Throughput Operations

This repo carries the suppression queue cleaner used by Yournotify Postal nodes.
It is intended for promotional and transactional nodes that run the official Postal
installer layout under `/opt/postal/install` with config mounted from `/opt/postal/config`.

It also carries a conservative held-message releaser for retryable holds. Postal's
manual retry queues a held message with `manual: true`, which bypasses suppression
and credential-hold checks. For that reason, the automated releaser defaults to
send-limit holds only and explicitly skips suppression-list, credential, development
mode, spam, missing-domain, and missing-recipient holds.

## Suppressed Queue Cleaner

Postal normally checks the suppression list after a worker locks a queued message.
That means suppressed recipients can still consume sender worker time before being
marked `Held`. The cleaner at `script/ops/suppressed_queue_cleaner.rb` moves that
work outside the sender worker pool:

- selects unlocked outgoing queued messages whose recipient is currently suppressed;
- locks them with a cleaner-specific lock;
- creates the normal Postal `Held` delivery record through Postal models;
- removes the queued row;
- unlocks rows it cannot safely process.

Install on a Postal host:

```bash
cd /path/to/postal
sudo script/ops/install_suppressed_queue_cleaner.sh [worker-count]
```

The optional `worker-count` also persists Docker Compose worker scale through
`/opt/postal/install/hooks/post-start` and `/opt/postal/install/worker-replicas`.
Omit it when you only want the cleaner and indexes.

## Current Node Sizing

- `mail.yournotify.net` / promotional-01: 8 vCPU, 16 GB RAM, 20 workers.
- `smtp.yournotify.net` / transactional: 2 vCPU, 4 GB RAM, 1 worker container with existing internal worker threads.
- promotional-02 should use the same cleaner and indexes from day one. For a same-size promotional-02, use 20 workers unless host metrics support more.

Postal v3 uses the singular `worker.threads` configuration path. A
`workers: { threads: ... }` section is ignored and leaves the runtime at the
default of two threads per worker container. Always confirm the effective value
inside the image before changing either container count or thread count:

```bash
docker exec postal-web-1 bundle exec rails runner \
  'puts Postal::Config.worker.threads'
```

## Verification

```bash
docker ps --format '{{.Names}}' | grep -E '^postal-worker-' | wc -l
systemctl is-enabled postal-suppressed-queue-cleaner.timer
systemctl is-active postal-suppressed-queue-cleaner.timer
journalctl -u postal-suppressed-queue-cleaner.service -n 20 --no-pager
```

Useful queue check:

```sql
SELECT COUNT(*) AS queued_count,
       SUM(locked_by IS NULL AND locked_at IS NULL AND (retry_after IS NULL OR retry_after < NOW() - INTERVAL 30 SECOND)) AS ready_count,
       SUM(locked_by IS NOT NULL OR locked_at IS NOT NULL) AS locked_count,
       SUM(retry_after IS NOT NULL AND retry_after >= NOW() - INTERVAL 30 SECOND) AS delayed_count
FROM postal.queued_messages;
```

## Held Message Releaser

Install on a Postal host:

```bash
cd /path/to/postal
sudo script/ops/install_held_message_releaser.sh
```

Defaults:

- runs every five minutes;
- releases at most 100 messages per run;
- only releases Held messages at least 15 minutes old;
- only allows delivery details matching `send limit`;
- skips suppression, credential hold, development mode, spam, missing-domain, and missing-recipient holds.

Override cautiously with systemd environment values:

```bash
sudo systemctl edit postal-held-message-releaser.service
```

```ini
[Service]
Environment=YN_HELD_MESSAGE_RELEASER_LIMIT=100
Environment=YN_HELD_MESSAGE_RELEASER_MIN_AGE_MINUTES=15
Environment=YN_HELD_MESSAGE_RELEASER_ALLOW_PATTERN=send limit
```

Run a one-off dry run inside a worker container:

```bash
docker exec -e YN_HELD_MESSAGE_RELEASER_DRY_RUN=1 postal-worker-1 bundle exec rails runner /config/scripts/held_message_releaser.rb
```

Useful Held reason check:

```sql
SELECT LEFT(COALESCE(d.details, ''), 140) AS details,
       COUNT(*) AS count
FROM `postal-server-1`.messages m
LEFT JOIN `postal-server-1`.deliveries d ON d.message_id = m.id AND d.status = 'Held'
WHERE m.status = 'Held'
GROUP BY LEFT(COALESCE(d.details, ''), 140)
ORDER BY count DESC
LIMIT 20;
```
