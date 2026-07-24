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
- Selar has three tracking-domain rows. `click.smtp.selarapp.com` is verified,
  while `click.selar.com` is missing and `click.selar.co` is invalid.
- Selar has approximately 10 million tracking-link rows, using about 1.9 GB,
  with the oldest dating to 2026-03-20. It has no link-pruning timer. Do not
  install a message-ID-only orphan cleaner: Selar retains message history for
  five days, but existing tracking links are substantially older.
- Selar's Caddy configuration is static. It has no certificate watcher, tracking
  host sync, queue cleaner, held-message releaser, disk guard, or link-pruner
  systemd units.
- Selar lacks the promotional node's queue-ready, server/message, and composite
  suppression indexes.
- Selar has no HTTP route endpoints and one enabled HTTPS webhook. Its destination
  is a public AWS API Gateway hostname, so the new SSRF guard does not require a
  private-destination allowlist entry.

## Prepared application baseline

- Postal upstream: 3.3.7.
- Yournotify domain API and branding.
- Configurable dequeue batch size.
- Priority queue support and its main-database migration.
- Default tracking-domain fallback.
- Suppression cleaner and conservative held-message releaser.
- Raw-message retention recovery.
- Caddy-to-Postal SMTP certificate synchronization scripts.
- DNS-verified Postal tracking-domain synchronization into a marked Caddy block.
- Dotted tracking labels such as `click.smtp`, formerly carried only by the
  promotional web image's `clickdots` patch.

## Reference-node findings

The promotional node uses two separate sources of truth for click domains:

1. Postal's `track_domains` table records the domains Postal has DNS-verified.
   A minute timer turns those rows into explicit Caddy sites.
2. Yournotify's `sender_click_domains` table authorizes Caddy on-demand TLS
   through `/health/caddy/track-domain/allow`, scoped by delivery region.

On 2026-07-24, Postal had 24 verified click domains for the promotional node,
but the Yournotify API authorized only 12 for `promotional-01`. The existing
sync script explicitly provisions all 24, which bypasses the authorization API
for the other 12. Do not copy that drift to Selar. Selar is not represented in
Yournotify's account database, so its safe initial model is:

- static Caddy sites for `smtp.selarapp.com`, `click.smtp.selarapp.com`, and
  `track.smtp.selarapp.com`;
- managed Caddy sites only for Postal rows whose DNS state is `OK`;
- no public on-demand TLS catch-all unless Selar gains its own authorization
  endpoint and region mapping.

The versioned sync script preserves the static Caddy configuration and only
rewrites content between explicit managed markers. It also ignores a verified
hostname already present in a static block, preventing duplicate Caddy sites.

Every static and managed tracking-domain proxy must send
`X-Postal-Track-Host: 1`. Postal's tracking middleware uses that header to
distinguish tracking requests from normal web requests; without it, rewritten
links do not reach the redirect lookup. Set `POSTAL_TRACK_SYNC_DRY_RUN=1` to
render the proposed complete Caddyfile without changing or reloading Caddy.

The promotional host is currently at 98% root-disk utilization. It is suitable
as a behavior reference, but it should not receive an image upgrade until space
has been reclaimed and backups have been verified. It also runs 24 worker
containers even though its persisted scale and post-start hook specify 20; use
the persisted value as intent and treat the extra four containers as drift.

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
9. Reconcile Postal-verified click domains against the system allowed to issue
   certificates for that node; do not assume the two databases agree.

## Migration order

1. Build and test the 3.3.7 Yournotify image without deploying it.
2. Synchronize Caddy's valid certificate and key into Postal, verify their
   hostname, expiry, and key match, then verify STARTTLS before any wider restart.
3. Install the certificate watcher so future Caddy renewals update Postal.
4. Drain or reduce the queue before altering `queued_messages`.
5. Apply Postal migrations through Postal's update command.
6. Add operational indexes one at a time and observe MariaDB locks.
7. Add the managed Caddy markers and run the tracking sync once before enabling
   its minute timer.
8. Start one web, one SMTP, and one worker container.
9. Verify login, API domain operations, SMTP AUTH, DKIM, return path, tracking,
   webhook delivery, suppression behavior, and certificate presentation.
10. Increase worker concurrency according to Selar's resources and metrics.
11. Enable the suppression cleaner only after comparing its candidate count.
12. Run the held-message releaser in dry-run mode before enabling its timer.

Selar's Compose project is `install`, so operations that scale services must set
`POSTAL_COMPOSE_PROJECT=install`. Its application containers are
`install-web-1`, `install-smtp-1`, and `install-worker-1`; the shared Caddy and
MariaDB containers remain `postal-caddy` and `postal-mariadb`.

Do not enable link pruning during the initial Selar upgrade. Its current link
growth is modest relative to the approximately 162 GB free disk, so preserving
the existing redirect history is safer. After the upgrade observation window,
agree a customer-facing policy before enabling the age-aware cleaner. A
365-day policy is conservative for Selar's observed footprint and comfortably
covers one- and two-week-old campaigns.

## Rollback boundary

Retain the previous images and complete database/config backups until message
submission, delivery, DNS checks, tracking, webhooks, and TLS have remained
healthy through the agreed observation window.
