# Certificates and DNS

Two questions that look like one and are not: **what a browser must trust**, and
**what one machine proves to another**. The first depends on what you choose.
The second never does.

## The names to publish

Every address derives from `UT_DOMAIN`. Six names have to resolve to the
appliance:

| Name | Serves |
|---|---|
| `<UT_DOMAIN>` | the platform and its API |
| `llms.<UT_DOMAIN>` | the models application |
| `assistants.<UT_DOMAIN>` | the assistants application |
| `admin.<UT_DOMAIN>` | the administration portal |
| `builder.<UT_DOMAIN>` | the App Builder |
| `*.apps.<UT_DOMAIN>` | one per generated application |

The last one is a wildcard **two levels below the apex**. A `*.<domain>`
wildcard does not match it — this catches people out on both DNS and
certificates.

A single A record per name, pointing at the machine. Nothing else is required.

## Choosing how TLS is terminated

`UT_INGRESS_MODE` has three values. Pick by what you have, not by what sounds
safest.

### `internal` — the default

Caddy signs its own certificates. Nothing to obtain, nothing to renew, works on
a `.local` name where no public authority will ever issue.

The browser warns on first visit. To remove the warning, install the
appliance's root on the machines that use it:

```bash
docker exec ut-caddy cat /data/caddy/pki/authorities/local/root.crt > ut-root.crt
```

Then add `ut-root.crt` to the operating system or browser trust store. The
fingerprint is stable across restarts, so this is done once per machine.

Use it for a pilot, an isolated network, or a `.local` address.

### `custom` — you supply the certificate

```bash
UT_INGRESS_MODE="custom"
UT_CERT_DIR="/etc/understandtech/certs"
```

The directory is mounted read-only and must hold `fullchain.pem` and
`privkey.pem`. The certificate has to cover the apex and the four satellite
names.

For the generated applications, supply their wildcard separately — a
single-level wildcard does not reach `*.apps.<domain>`:

```bash
UT_APPS_CERT_FILE="/etc/caddy/certs/apps-fullchain.pem"
UT_APPS_KEY_FILE="/etc/caddy/certs/apps-privkey.pem"
```

**Renewal is yours.** Nothing on the appliance watches the expiry date. Replace
the files and **restart** Caddy:

```bash
docker compose restart caddy
```

**A reload is not enough, and this is the trap.** Caddy keeps the certificate
it loaded in memory. `caddy reload` re-reads the configuration and reports
success — but the file path has not changed, so it does not read the file
again.

Measured on Caddy 2 with a certificate replaced on disk:

| | Certificate served |
|---|---|
| At startup | the first one |
| After replacing the files | the first one — nothing happens |
| After `caddy reload`, acknowledged | the first one — still |
| After `docker compose restart caddy` | the new one |

So a renewal that ends with a reload leaves the appliance serving the expired
certificate, with nothing saying so until a browser refuses it.

This is not held by a check. One was written and removed: it passed locally and
failed on CI for reasons that took longer to chase than the behaviour is likely
to change. If a future Caddy picks the file up on reload, this table is what
goes out of date.

A missing or unreadable file stops Caddy from starting rather than degrading
quietly — `caddy validate` reads the certificates for real, and it is also the
healthcheck. `sudo ./ut-install --check` catches it before the first `up`.

### `edge` — your load balancer terminates TLS

```bash
UT_INGRESS_MODE="edge"
UT_CADDY_SCHEME="http"
UT_PUBLIC_SCHEME="https"
UT_TRUSTED_PROXIES="10.42.0.0/16"
```

Four settings, and each one matters.

`UT_CADDY_SCHEME="http"` is what makes Caddy serve plain HTTP. `auto_https off`
does not replace it: with a bare site address Caddy still listens on 443 only,
and your balancer knocking on 80 finds nobody home.

`UT_PUBLIC_SCHEME` stays `https` — it is the scheme the applications advertise
to the browser, and the browser really is on HTTPS. Setting it to `http` breaks
the OIDC round trip.

`UT_TRUSTED_PROXIES` is what makes Caddy honour `X-Forwarded-*`. **Narrow it to
the network your balancer speaks from.** The `private_ranges` default lets any
machine on the LAN claim any source address.

## The machine-facing surface

Separate from all of the above, and not affected by it.

`node.<UT_DOMAIN>:8443` always serves a certificate from the appliance's own
authority, in every ingress mode. Two reasons.

It keeps the authority working. An authority that issues nothing rots until the
day something needs enrolling — and in `custom` or `edge` the public certificate
comes from you, so it would issue nothing at all.

And it gives you something to verify. Bound to `127.0.0.1` by default. If your
load balancer would rather verify the appliance than trust it blindly:

```bash
UT_INTERNAL_BIND_ADDRESS="10.42.0.7"
```

Then add the authority's root to the balancer's trust store:

```bash
cat /var/lib/understandtech/ca/certs/root_ca.crt
```

Optional. `edge` works without it.

## The local authority

It runs as `ut-step-ca`, issues certificates lasting **seven days**, and renews
them on its own. You do not operate it day to day.

Three facts worth knowing.

**Its root is at `${DATA_ROOT}/ca`**, which is what the file backup covers.
Losing it means re-enrolling everything it ever issued, so it is deliberately
inside the backed-up path rather than in a Docker volume, which nothing backs
up.

**A machine switched off longer than seven days recovers by itself.** The
authority accepts renewing an expired certificate, so a box that spent a
holiday unplugged comes back without a visit.

**That is only safe because revocation still works.** Revoking a certificate
refuses its renewal immediately, expired or not. Nothing revokes anything today
— nothing is enrolled — but the revocation command has to exist before the
first machine is enrolled.

To inspect what it is serving:

```bash
docker exec ut-step-ca step certificate inspect /home/step/certs/root_ca.crt --short
```

## Changing the address later

`UT_DOMAIN` is the only place the name is written; every URL derives from it.

```bash
# in /opt/understandtech/.env
UT_DOMAIN="box.example.com"
```

```bash
docker compose up -d
```

Publish the six DNS records first, and replace the certificate if you are in
`custom` mode — the old one no longer matches. Users signed in through OIDC have
to sign in again: the redirect URI changed.
