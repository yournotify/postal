# Tracking Domain Automation Standard

This repository supports one customer tracking-domain model: Caddy On-Demand
TLS authorized by the local Postal database. Static Caddy sites are reserved
for the dashboard/SMTP hostname, the deployment's unified default tracking
hostname, and unrelated services such as MTA-STS.

## Authority

Postal's local `track_domains` table is the only customer-host authorization
source. Caddy may issue a certificate only when the exact tracking hostname:

- has `dns_status: OK`;
- has SSL enabled;
- belongs to a non-deleted, non-suspended server; and
- belongs to a non-deleted, non-suspended organization.

`GET /health/caddy/track-domain/allow?domain=<hostname>` returns `204` when all
conditions pass and `404` otherwise. Caddy calls it over host-local networking:

```text
http://localhost:5000/health/caddy/track-domain/allow
```

The endpoint performs an indexed database lookup. It does not make a DNS or
other network request during the TLS handshake.

Do not maintain an external allowlist, a deployment/server scope, or a shared
authorization token. Do not add customer tracking hosts to Caddy manually.

## Lifecycle

1. An operator or application creates a tracking domain in Postal.
2. Postal checks that the exact hostname has one CNAME pointing to the
   deployment's `dns.track_domain` value.
3. Postal automatically refreshes tracking-domain DNS status every five
   minutes. **Check DNS** performs an immediate refresh.
4. A browser opens an HTTPS tracking link and Caddy asks local Postal whether
   that hostname is eligible.
5. Postal returns `204` only for an eligible exact hostname.
6. Caddy obtains or reuses the certificate and proxies the tracking request.

Once Postal displays **CNAME configured correctly**, no separate Caddy sync
window exists. The first HTTPS request can initiate certificate issuance.

## Required DNS

If `dns.track_domain` is `track.smtp.example.com`, the customer record is:

```text
click.customer.example CNAME track.smtp.example.com
```

Use DNS-only mode. It must not point at the SMTP/dashboard hostname. A proxied
record that returns provider A/AAAA addresses instead of the required CNAME
will not pass Postal verification.

## Caddy configuration

The global authorization policy is:

```caddyfile
{
  on_demand_tls {
    ask http://localhost:5000/health/caddy/track-domain/allow
  }
}
```

Keep explicit static blocks for core hosts. Customer hosts use one catch-all:

```caddyfile
:443 {
  tls {
    on_demand
  }
  reverse_proxy 127.0.0.1:5000 {
    header_up Host {host}
    header_up X-Real-IP {remote_host}
    header_up X-Forwarded-For {remote_host}
    header_up X-Forwarded-Proto {scheme}
    header_up X-Postal-Track-Host "1"
  }
}
```

The tracking header is required so Postal's tracking middleware handles click
and open routes. The catch-all alone is safe because Caddy cannot obtain a
certificate unless the local Postal endpoint approves the requested SNI name.

## Installation and migration

Deploy the Postal image containing the local authorization endpoint first.
Then dry-run the versioned migration on each host:

```bash
sudo POSTAL_WEB_CONTAINER=<compose-web-container> \
  POSTAL_CADDY_CONTAINER=postal-caddy \
  POSTAL_CADDY_CONFIG_FILE=/opt/postal/config/Caddyfile \
  POSTAL_ON_DEMAND_DRY_RUN=1 \
  script/ops/caddy/migrate_postal_on_demand_tls.sh
```

Review the complete proposed Caddyfile, then run without
`POSTAL_ON_DEMAND_DRY_RUN`.

The migration:

- verifies that a known eligible hostname returns `204` and a denied hostname
  returns `404` from local Postal;
- removes the retired generated-host block;
- removes explicit customer tracking blocks found in Postal;
- refuses to proceed if a tracking proxy block contains an unknown hostname;
- preserves the static unified default tracking hostname;
- replaces an external ask endpoint with the local endpoint, or creates the
  global policy when absent;
- creates the on-demand catch-all when absent;
- validates the complete Caddy configuration before reload;
- restores the timestamped backup if validation or reload fails; and
- disables the retired `postal-track-host-sync.timer` after success.

## Verification

Test the authorization decision locally:

```bash
curl -i 'http://localhost:5000/health/caddy/track-domain/allow?domain=click.customer.example'
curl -i 'http://localhost:5000/health/caddy/track-domain/allow?domain=not-approved.invalid'
```

Expected statuses are `204` and `404`, respectively.

Validate Caddy and HTTPS:

```bash
docker exec postal-caddy caddy validate \
  --config /etc/caddy/Caddyfile --adapter caddyfile
curl --head https://click.customer.example/
```

A Postal `404` for an invalid click token still proves DNS, TLS, and proxy
routing. Use a controlled real tracking link to verify the redirect itself.

## Removal and suspension

Deleting a tracking domain, disabling SSL, suspending its server or
organization, or losing the required CNAME makes subsequent Caddy authorization
requests return `404`. Existing certificates may remain in Caddy storage until
their normal cleanup, but the hostname is no longer authorized for new issuance
or renewal. Remove DNS when retiring a hostname.

## Failure handling

- **CNAME missing:** create the exact DNS-only CNAME shown by Postal.
- **CNAME invalid:** replace its target with the exact configured tracking
  target and disable DNS proxying.
- **DNS correct but Postal stale:** click **Check DNS** or wait up to five
  minutes.
- **Postal says Good but TLS fails:** check the local allow endpoint, public DNS,
  ports 80/443, Caddy logs, and CA rate limits.
- **TLS works but the link does not redirect:** check the tracking token and
  Postal tracking route independently of DNS and certificate issuance.
