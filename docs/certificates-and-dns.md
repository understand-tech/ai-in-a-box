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

### `custom` with automatic renewal — nothing to install anywhere

The `internal` mode asks every machine that uses the appliance to install a
root: three procedures depending on the operating system, a file moved around
by USB or e-mail, once per machine. On four hundred workstations without an IT
department, that is the single heaviest thing about this product.

A publicly trusted certificate removes it entirely — browsers already trust the
authority. `ut-certificate` obtains and renews one.

```bash
./ut-certificate --check      # what is configured, and what expires when
./ut-certificate              # obtain, or renew within 30 days of expiry
./ut-certificate --install    # renew daily from cron
```

**Validation is DNS-01, so the appliance is never reached from the internet.**
It proves the domain by writing a DNS record, not by answering a request.
Nothing is exposed, no port is opened, and it works behind any firewall with
outbound access.

That is also the only method that can cover `*.apps.<domain>`: a wildcard two
levels below the apex, which HTTP validation cannot prove.

```bash
UT_INGRESS_MODE="custom"
UT_ACME_EMAIL="ops@example.com"
UT_ACME_DNS_PROVIDER="cloudflare"
UT_ACME_DNS_ENV="CF_DNS_API_TOKEN=xxxxx"
```

`lego dnshelp -c <provider>` lists what a given provider expects; about two
hundred are supported. Credentials reach the tool through the environment, so
they stay out of the process table and out of your shell history.

**What it needs**, and what it therefore rules out:

- a real domain — `.local` cannot be certified by anyone, and `--check` says so
  rather than failing later;
- outbound access to the authority — an air-gapped appliance keeps `internal`;
- control of the DNS zone.

Renewal restarts Caddy, because a reload does not pick up a replaced
certificate. That is a few seconds of downtime every sixty days, at 03:17.

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

## Adding a second machine

A compute node serves inference to the machine that holds the data. Part of
this works today, part does not, and the difference matters before you promise
anything to a customer.

### What works

The role itself. `compose.compute.yaml` keeps the inference engines and Caddy
and switches off everything belonging to the control plane, so the second
machine runs no database and no application:

```bash
COMPOSE_FILE="compose.yaml:compose.compute.yaml"
COMPOSE_PROFILES="nim"
NIM_LLM_BIND_ADDRESS=<address the control plane reaches>
NIM_VLM_BIND_ADDRESS=<same>
```

**Those two addresses are required on a compute node and nowhere else.** Left
at their default the engines listen on loopback, so the node starts, passes its
healthcheck, and serves nobody — a failure that reads as a model problem rather
than a binding one.

`llm` is switched off there too, and that is a limitation rather than a choice:
it carries the embedding and reranking work, but it also reads the customer's
documents and talks to MongoDB, so it cannot run on a machine that holds
neither. A compute node therefore serves generation and vision, where the GPU
time goes, while indexing stays on the machine with the data.

### What does not work yet

**Enrolling that machine against the authority.** There is no `ut-enrol`, and
no `ut-revoke`. The mechanism is proven — `test/machine-identity.sh` checks ten
properties offline, including that a single-use token issues a certificate,
that replaying it is refused, that renewal needs no token, and that a revoked
node cannot renew even after expiry — but nothing in the product performs it.

Until then, a compute node is reachable on an address you opened, with no
certificate proving which machine it is. On a network you control, between two
machines you own, that is a deliberate and bounded choice. It is not mutual
authentication.

### The order these have to be built in

**Revocation comes before the first enrolment**, and this is not a preference.

The authority issues certificates lasting seven days with
`allowRenewalAfterExpiry` on, so a machine switched off longer than that
recovers by itself — which is what an appliance in a rack needs. That setting
also removes the only revocation mechanism available without a distribution
list: letting the certificate lapse.

With nothing enrolled, there is nothing to revoke and no risk. The day a second
machine holds a certificate, the absence of `ut-revoke` means **any machine that
ever held one can reactivate itself indefinitely** — worse than either
alternative. Measured, not assumed: explicit revocation refuses renewal
immediately, expired or not.

So: `ut-revoke` and its procedure, then enrolment. Not the reverse.

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
