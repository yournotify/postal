# Selar Postal Upgrade Preflight

This runbook prepares the Yournotify Postal fork for an in-place Selar upgrade.
Do not deploy until the live Selar image, database schema, queue, certificates,
host resources, and rollback artifacts have been recorded.

## Prepared application baseline

- Postal upstream: 3.3.7.
- Yournotify domain API and branding.
- Configurable dequeue batch size.
- Priority queue support and its main-database migration.
- Default tracking-domain fallback.
- Suppression cleaner and conservative held-message releaser.
- Raw-message retention recovery.
- Caddy-to-Postal SMTP certificate synchronization scripts.

## Configuration corrections

Postal's version 2 configuration uses `worker`, singular:

```yaml
worker:
  threads: 2
```

The following values belong under `dns`, not `smtp_server`:

```yaml
dns:
  dkim_identifier: postal
  domain_verify_prefix: postal-verification
  custom_return_path_prefix: psrp.smtp
  default_track_domain: track.smtp.selarapp.com
```

Do not change DKIM or verification prefixes during an upgrade without checking
all existing sender-domain records. Preserve the effective values from Selar.

Postal 3.3.7 blocks unsafe outbound HTTP destinations. Inventory webhooks and
HTTP routes before setting `postal.allowed_request_destinations`.

## Required read-only inventory

1. Record OS, CPU, RAM, swap, disk utilization, Docker and MariaDB versions.
2. Record every Postal container image tag, image ID, and creation time.
3. Record the main schema version and every message-database schema version.
4. Count queued, locked, delayed, held, and suppressed messages.
5. Back up `postal` and every `postal-server-*` database.
6. Back up `/opt/postal/config`, `/opt/postal/install`, Caddy data, systemd
   units, certificate hooks, and the current Docker image IDs.
7. Record Caddy's active configuration and validate its on-demand TLS policy.
8. Confirm the SMTP certificate, key permissions, issuer, expiry, and renewal.

## Migration order

1. Build and test the 3.3.7 Yournotify image without deploying it.
2. Drain or reduce the queue before altering `queued_messages`.
3. Apply Postal migrations through Postal's update command.
4. Add operational indexes one at a time and observe MariaDB locks.
5. Start one web, one SMTP, and one worker container.
6. Verify login, API domain operations, SMTP AUTH, DKIM, return path, tracking,
   webhook delivery, suppression behavior, and certificate presentation.
7. Increase worker concurrency according to Selar's resources and metrics.
8. Enable the suppression cleaner only after comparing its candidate count.
9. Run the held-message releaser in dry-run mode before enabling its timer.

## Rollback boundary

Retain the previous images and complete database/config backups until message
submission, delivery, DNS checks, tracking, webhooks, and TLS have remained
healthy through the agreed observation window.
