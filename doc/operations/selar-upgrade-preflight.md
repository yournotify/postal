# Selar Postal Upgrade Preflight

This runbook prepares the Yournotify Postal fork for an in-place Selar upgrade.
Do not deploy until the live Selar image, database schema, queue, certificates,
host resources, and rollback artifacts have been recorded.

## Observed Selar baseline

Read-only inventory on 2026-07-24:

- SSH origin: `46.226.108.227`, host `smtp.selarapp.com`.
- Postal image: `yournotify/postal:3.3.5-yournotify`.
- Image code matches fork commit `c880704`.
- Docker Compose project/container prefix: `install`, not `postal`.
- Main schema: `20240311205229`.
- Message database: `postal-server-1`, schema `20`, about 2.3 GB.
- Queue: empty during the inventory.
- `queued_messages.priority`: not installed.
- MariaDB: 10.11.16.
- Host: 8 vCPU, 7.2 GiB RAM, approximately 162 GiB disk free.
- No `/opt/postal/overrides` files or custom Postal systemd timers.
- Caddy serves the web and tracking hosts, but Postal SMTP certificate files
  `/config/smtp.crt` and `/config/smtp.key` are missing.
- Caddy's source certificate exists under `/opt/postal/caddy-data`, is valid
  through 2026-10-15, and can be synchronized with the versioned Caddy hooks.
- SMTP advertises STARTTLS but the handshake terminates before presenting a
  certificate. Repair and verify certificate synchronization before restarting
  or upgrading the SMTP container.

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
