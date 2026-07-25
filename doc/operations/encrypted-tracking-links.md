# Encrypted Self-Contained Tracking Links

Postal tracking links use the existing two-segment URL shape:

```text
https://click.example.com/<server-token>/<encrypted-token>
```

The encrypted token contains the destination URL and is authenticated with
AES-256-GCM. The `links` row is only a temporary analytics record. Removing the
row or its parent message does not prevent the encrypted token from redirecting.
There is deliberately no lookup fallback for old random tokens.

## Keyring

Generate a separate keyring for each Postal installation:

```bash
script/generate-tracking-link-keyring /opt/postal/config/tracking-keys.yml
chown 999:999 /opt/postal/config/tracking-keys.yml
chmod 0600 /opt/postal/config/tracking-keys.yml
```

The default path is `tracking-keys.yml` next to `postal.yml`. Override it with
`POSTAL_TRACKING_LINK_KEYS_PATH`. The file must be readable by Postal's
container user (UID/GID 999), mounted into every web, worker, and SMTP container
at the same path, and should remain mode `0600`.

Back up the keyring independently of the databases. Deleting a key permanently
breaks every delivered link encrypted with that key.

To rotate keys, add a new numeric key ID between 0 and 255, set it as `active`,
and restart Postal. Keep every previous key:

```yaml
active: 2
keys:
  1: <old 32-byte key encoded as strict Base64>
  2: <new 32-byte key encoded as strict Base64>
```

## Retention behavior

While the fingerprinted `links` row and parent message exist, Postal records the
click and sends the normal webhook. Postal's standard message-retention task
deletes associated link rows at the same time as expired message metadata, so
the dashboard's **Message retention days** setting controls both. After
retention removes either record, the visitor is still redirected but no Postal
analytics are written.

Old 16-character database tokens are intentionally rejected. Deleting their
rows makes previously delivered old-format links return `404`.
