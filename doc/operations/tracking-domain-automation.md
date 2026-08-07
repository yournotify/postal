# Tracking Domain Automation Standard

This is the single supported tracking-domain provisioning model for every
deployment built from this repository.

## Source of truth

Postal's local `track_domains` table is the only authorization source. A host
is eligible for Caddy only when its `dns_status` is `OK`. The expected CNAME is
the deployment-specific `dns.track_domain` value.

Do not maintain a second tracking-domain allowlist in another application. Do
not add customer tracking hosts to Caddy by hand.

## Lifecycle

1. An operator or an application creates a tracking domain in Postal.
2. Postal checks that the full hostname has exactly one CNAME pointing to
   `dns.track_domain`.
3. Postal automatically rechecks tracking-domain DNS every five minutes. The
   dashboard's **Check DNS** action can refresh it immediately.
4. `/usr/local/sbin/postal-track-host-sync` reads only DNS-verified rows.
5. The minute systemd timer renders those hosts between the managed markers in
   Caddy's configuration.
6. The synchronizer validates the complete Caddy configuration before reload.
   It restores the prior configuration if validation or reload fails.
7. Caddy obtains the HTTPS certificate when the verified host becomes active.

The normal automatic activation window after public DNS is correct is up to
approximately six minutes. Clicking **Check DNS** reduces that to approximately
one minute.

## Required DNS

For a deployment whose `dns.track_domain` is `track.smtp.example.com`, a
customer hostname must be a DNS-only CNAME:

```text
click.customer.example CNAME track.smtp.example.com
```

It must not point to the SMTP/dashboard hostname. A proxied record that returns
provider A/AAAA addresses instead of the configured CNAME will not pass Postal's
verification.

## Installation

Run from the checked-out release on each Postal host:

```bash
sudo POSTAL_WEB_CONTAINER=<compose-web-container> \
  POSTAL_CADDY_CONTAINER=postal-caddy \
  POSTAL_CADDY_CONFIG_FILE=/opt/postal/config/Caddyfile \
  script/ops/caddy/install_postal_track_sync.sh
```

The installer:

- adds the managed markers without changing static sites;
- installs the versioned synchronizer;
- runs it once;
- enables a persistent one-minute timer.

## Verification

```bash
systemctl is-enabled postal-track-host-sync.timer
systemctl is-active postal-track-host-sync.timer
systemctl status postal-track-host-sync.service --no-pager
```

```bash
sed -n \
  '/# BEGIN MANAGED POSTAL TRACK DOMAINS/,/# END MANAGED POSTAL TRACK DOMAINS/p' \
  /opt/postal/config/Caddyfile
```

```bash
curl --head https://click.customer.example/
```

A tracking request may return a Postal `404` when the path/token is invalid;
that still proves DNS, TLS, and Caddy routing are active. Test a real controlled
tracking link to verify the redirect path.

## Fleet migration

For a host that still uses an external on-demand TLS authorization endpoint:

1. Back up the current Caddyfile and Caddy data.
2. Inventory Postal tracking domains and compare them with the current Caddy
   authorization source.
3. Correct DNS-invalid Postal rows; do not provision them manually.
4. Install and dry-run the managed synchronizer.
5. Validate that every DNS-verified host appears in the proposed managed block.
6. Add the managed block and validate Caddy.
7. Remove the external on-demand catch-all only after every active host has an
   explicit static or managed site.
8. Reload Caddy and test representative tracking links.
9. Enable the minute timer and monitor certificate issuance.

Do not remove the old catch-all first. That can interrupt active customer links
whose host inventory has not yet been reconciled.

## Failure handling

- **Dashboard says CNAME missing:** create the required DNS-only CNAME.
- **Dashboard says CNAME invalid:** replace the returned target with the exact
  configured tracking target.
- **DNS is correct but dashboard is stale:** click **Check DNS** or wait up to
  five minutes.
- **Dashboard is OK but host is absent from Caddy after one minute:** inspect
  the systemd service log and Caddy validation output.
- **Caddy has the host but HTTPS fails:** inspect certificate issuance, public
  DNS propagation, port 80/443 reachability, and CA rate limits.
- **HTTPS works but a link does not redirect:** verify the tracking token and
  application route separately from DNS/TLS.
