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

## Raw Message Disk Guard

Postal's built-in raw-message size retention runs at 03:00 and removes whole
daily raw tables. A busy node can therefore exceed its configured size by a
full day's raw traffic before cleanup. Install the hourly enforcer to apply the
existing per-server `raw_message_retention_size` throughout the day:

```bash
cd /path/to/postal
sudo script/ops/install_raw_message_retention_enforcer.sh
```

The timer runs at ten minutes past each hour to avoid overlapping Postal's
built-in 03:00 retention task. It does not change the configured retention
limit. It only invokes Postal's normal table-removal method when the recorded
raw-message size is already over that limit.

## Tracking Link Retention

Postal's encrypted self-contained tracking links do not depend on the
token-to-URL row after delivery. The row is temporary analytics data and the
normal message-retention task removes it with its parent message. The encrypted
URL continues redirecting after both records are gone.

The standalone orphan-link pruner is only for installations that still generate
legacy database-dependent tokens. Do not enable it on encrypted-link nodes:

```ini
[Service]
Environment=YN_LINK_RETENTION_DAYS=30
```

On a legacy node, the orphan-link pruner defaults to 30 days and deletes a row
only when both:

- its parent message is outside the retained message-ID range; and
- the link timestamp is older than `YN_LINK_RETENTION_DAYS`.

On encrypted-link nodes, choose **Message retention days** solely for the
analytics window. A value of one day keeps one day of Postal metadata and link
analytics while the redirect itself remains functional indefinitely. Deleting
link rows frees pages inside InnoDB but does not immediately shrink the `.ibd`
file; rebuild the table only during a planned maintenance window when
`data_free` is material and enough temporary disk space exists.

On `mail.yournotify.net`, the compacted table used about 1 GB for 5.2 million
rows generated over two days. At that observed rate, 21 days is approximately
10–11 GB and 30 days is approximately 15 GB. Use 21 days on the current 50 GB
volume unless the volume is expanded; it still gives a full week of margin
beyond the two-week click requirement. A sample of recent promotional rows was
about 25% duplicate message/URL pairs, so future per-message link deduplication
could reduce this further, but it is not required for the Selar upgrade.
