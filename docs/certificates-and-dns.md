# Certificates and DNS

For the operator deciding how an appliance is reached and trusted. After
reading you will know which names to publish, which of the three TLS modes
fits, and what the local authority does whichever one you pick.

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

`understand.local` is the exception, and the only one: mDNS answers for `.local`
and nothing else, so on that address the appliance publishes the names itself
through `ut-mdns-alias` and Avahi. That reaches one flat network segment, never
crosses a router, and no public authority will ever certify it.

**The installer follows the address.** Give it a `.local` name and it installs
the mDNS publisher; give it anything else and it installs neither the publisher
nor a dependency on Avahi, because the names are yours to publish. Changing
`UT_DOMAIN` off `.local` later and re-running `setup-autostart.sh` disables the
publisher that was installed before.

## Deciding by what the site already has

Two questions decide everything, and they are **independent**: who resolves the
six names, and who is trusted for the certificate. What follows is what each
answer costs on the machines people actually use — which is the cost that
matters, because it is the one you cannot do yourself.

### Who resolves the names

| What the site has | What to publish | What each machine needs |
|---|---|---|
| **A DNS server** — a domain controller, a resolver, a firewall that answers | three records: the apex, `*.<domain>`, `*.apps.<domain>` | **nothing** |
| **No DNS server, one flat segment** | nothing: give the appliance a `.local` address and it publishes the names itself | nothing on macOS. **Two changes on Linux** — below. Windows is **unverified** |
| **No DNS server, no mDNS** | nothing | five lines in `/etc/hosts`, per machine — **and generated applications stay unreachable**, because `hosts` has no wildcard |

Three records, not six: `*.<domain>` covers the four satellite names. The third
is needed because a single-level wildcard does not reach `*.apps.<domain>`.

### Who is trusted

| What the site has | Mode | What each machine needs |
|---|---|---|
| **An internal PKI** — AD Certificate Services, or any enterprise CA | `custom` | **nothing.** Their machines already trust that root |
| **A load balancer holding your own certificate** | `edge` | **nothing**, for the same reason |
| **A public domain and outbound access** | `custom` with `ut-certificate` | nothing. Not available on an isolated site |
| **None of those** | `internal`, the default | the appliance's root — one import, and **that import can be pushed** |

**The fewest actions on user machines is an internal PKI.** Nothing else comes
close: the appliance presents a certificate the fleet already trusts, and no one
visits a desk. If the site has AD Certificate Services, ask for a certificate
covering the apex, `*.<domain>` and `*.apps.<domain>`, and use `custom`.

### Pushing the root instead of visiting every desk

In `internal` mode the root has to reach each machine. On a managed fleet that
is one administrator task, not one task per person.

| Fleet | Where the root goes |
|---|---|
| **Windows, Active Directory** | Group Policy → Computer Configuration → Policies → Windows Settings → Security Settings → Public Key Policies → **Trusted Root Certification Authorities** |
| **Intune, or any MDM** | a **trusted certificate** profile — Windows, macOS, iOS and Android all take one |
| **macOS, Jamf** | a configuration profile carrying a certificate payload |
| **Linux, configuration management** | the file into `/usr/local/share/ca-certificates/`, then `update-ca-certificates` |

**On Linux the system store is not the whole story.** Firefox keeps its own, and
Chrome reads an NSS database rather than `/etc/ssl/certs`. A fleet that pushes
only to the system store will still see warnings in those browsers.

Export the root from the appliance first:

```bash
docker exec ut-caddy cat /data/caddy/pki/authorities/local/root.crt > ut-root-ca.crt
openssl x509 -in ut-root-ca.crt -noout -subject -fingerprint -sha256
```

**Keep that fingerprint and publish it by another route** — on the delivery note,
or wherever the site records such things. Whoever receives the file has no other
way to tell it apart from a root someone else supplied.

### A `.local` address on Linux clients

Measured on a stock Ubuntu client: `mdns4_minimal` resolves `.local` names of
**exactly two labels**. The apex answers; `admin.<domain>` and the satellites do
not, because they have three.

The fix has **two halves, and each is inoperative alone**:

- `mdns4` in the `hosts:` line of `/etc/nsswitch.conf`;
- `.local` listed in `/etc/mdns.allow`.

Applying one of the two looks like it worked — the apex already resolved — and
leaves every satellite unreachable.

macOS resolves all three depths natively, verified. **Windows has never been
measured**, so do not plan on it without checking first.

### What an isolated site removes from the list

`ut-certificate` needs to reach a public authority and a DNS provider's API, so
on a site with no outbound access it is **not an option**. Everything else in
both tables still applies: an internal PKI is still the answer with the fewest
actions, and the appliance's own authority is still the fallback.

## Choosing how TLS is terminated

Three ways, chosen when you install. Pick by what you have, not by what sounds
safest. Each is kept by later runs of `ut-install`.

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
sudo ut-install --certificate-dir /etc/understandtech/certs
```

The directory must hold `fullchain.pem` and `privkey.pem`; it is mounted
read-only. Before anything is written, the installer refuses a missing file, a
key that is not the certificate's, a certificate that has expired, and one
that does not cover the apex and the four satellite names — naming what is
wrong.

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
healthcheck. `sudo ./bin/ut-install --check` catches it before the first `up`.

### `custom` with automatic renewal — nothing to install anywhere

The `internal` mode asks every machine that uses the appliance to install a
root: three procedures depending on the operating system, a file moved around
by USB or e-mail, once per machine. On four hundred workstations without an IT
department, that is the single heaviest thing about this product.

A publicly trusted certificate removes it entirely — browsers already trust the
authority. `ut-certificate` obtains and renews one.

```bash
./bin/ut-certificate --check      # what is configured, and what expires when
./bin/ut-certificate              # obtain, or renew within 30 days of expiry
./bin/ut-certificate --install    # renew daily from cron
```

> **Installed from the package, tell it where the settings are.**
> `ut-certificate` looks for `.env` in `/opt/understandtech`, which is where a
> git checkout puts it. The package puts the release in
> `/usr/share/understandtech` and the settings in `/etc/understandtech`, so the
> commands above find no `.env` unless you say:
>
> ```bash
> sudo UT_INSTALL_DIR=/usr/share/understandtech ut-certificate --check
> ```
>
> Export it for `--install` too, or the cron job it writes has the same problem.

**Validation is DNS-01, so the appliance is never reached from the internet.**
It proves the domain by writing a DNS record, not by answering a request.
Nothing is exposed, no port is opened, and it works behind any firewall with
outbound access.

That is also the only method that can cover `*.apps.<domain>`: a wildcard two
levels below the apex, which HTTP validation cannot prove.

```bash
UT_ACME_EMAIL="ops@example.com"
UT_ACME_DNS_PROVIDER="cloudflare"
UT_ACME_DNS_ENV="CF_DNS_API_TOKEN=xxxxx"
```

The first certificate it installs is the one the front door serves from then
on: `ut-certificate` switches the appliance to `custom` itself.

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
sudo ut-install --behind-proxy 10.42.0.0/16
```

The range is the network your balancer connects from — a CIDR, or several
separated by commas. Caddy then serves plain HTTP, and believes the client
address in `X-Forwarded-*` from that range only. A range that would believe
anyone, `0.0.0.0/0`, is refused.

The addresses the applications give the browser stay on `https`, which is what
the browser is on.

## The local authority

Caddy keeps its own, in the `ut-caddy-data` volume. Its root lasts ten years;
Caddy renews its intermediate itself, every few days, with no network. It signs
the public names in `internal` mode. Exporting and trusting it is the same
command as [`internal` mode](#internal--the-default) above.

## The link authority

A second authority in the same volume, `link`, signs only what two boxes show
each other once they are paired: never a name a browser sees. The file backup
leaves it out, so a restored box is paired again instead of passing for the one
it was restored from.

## Adding a second machine

A compute node serves inference to the machine that holds the data.

### Installing the compute node

`compose.compute.yaml` keeps the inference engines and Caddy and switches off
everything belonging to the control plane, so the second machine runs no
database and no application. On that machine:

```bash
sudo ut-install --compute <IP or DNS name the control plane reaches it by>
```

The address cannot be a `.local` name: the control plane's containers do not
resolve mDNS. The install starts no platform, asks for no domain, and ends by
printing how to pair a platform with it. Later runs keep the role.

The engine publishes no port of its own. Caddy serves it on port 8444 to the
platforms paired with the node, and to nothing else: until one is, the port
does not answer.

### Pairing a platform with it

On the platform, name the node by the same address:

```bash
sudo ut-install --inference-from <node>
```

It takes the inference from the node instead of starting an engine, and it
downloads no weights for the model, on this run or later ones: only those of
`llm`. Then pair the two, within 15 minutes:

```bash
# on the compute node
sudo ut-pair offer
# on the platform, with the code the node shows
sudo ut-pair join <node>
```

`ut-pair offer` shows a code of 24 letters and digits; `ut-pair join` asks for
it, never on the command line. The two machines exchange the roots of their link
authorities, sealed with that code. From then on the node serves the platform's
certificate, and the platform trusts the node's root and no other. The pairing
port, 8447, is open for those 15 minutes only.

The platform's services call its own Caddy, at `http://caddy:8445/v1`, with
`VLLM_API_KEY`, which never leaves the platform. Caddy carries each call to the
node under the platform's certificate.

Give the control plane a GPU if its users chat over their documents: `llm` runs
there, and does not start without one.

`llm` is switched off on the compute node, and that is a limitation rather than
a choice: it carries the embedding and reranking work, but it also reads the
customer's documents and talks to MongoDB, so it cannot run on a machine that
holds neither. A compute node therefore serves generation and vision, where the
GPU time goes, while indexing stays on the machine with the data.

### Unpairing a platform

On the compute node:

```bash
sudo ut-pair list
sudo ut-pair forget <the first characters of the platform's fingerprint>
```

The node refuses the platform as soon as Caddy has reloaded; a generation already
under way finishes. If Caddy refuses the new list, `ut-pair forget` says so, and
the platform stays served until Caddy restarts.

A restored box has a new link authority: pair it again with each box it was
paired with, and forget its old fingerprint there.

### Taking the inference back on the platform

A platform with a GPU of its own can serve its model again:

```bash
sudo ut-install --inference-here
```

It takes the relay and the settings `--inference-from` wrote out of
`local.env`, starts the engine, and downloads the model's weights. It is refused
when the GPU does not answer `nvidia-smi`, and with `--inference-from`,
`--no-gpu`, `--compute` or `--arbiter`. Later runs keep the role.

What `ut-pair` recorded stays, and serves nothing: forget it on both machines,
as above, the platform's link on the node and the node's on the platform.

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

## What this document does not cover

**Your DNS provider.** Which records to publish is here; how to publish them is
your provider's business. `ut-certificate` needs provider credentials for
DNS-01 — `lego dnshelp` lists what each one wants.

**The identity provider's own certificate.** Sign-on is configured in the
browser, not here; see
[first-run configuration](first-run-configuration.md#2--configure-sign-on).

**What a user sees when a certificate is not trusted**, and what to tell them.
That is [using the platform](using-the-platform.md#the-first-time-a-certificate-warning).

**Certificates inside generated applications.** The App Builder's apps are
served by the same wildcard site, so they inherit whatever the apex uses; they
have no certificate of their own.
