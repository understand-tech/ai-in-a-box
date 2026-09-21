# UnderstandTech — AI in a Box

Deploy the UnderstandTech platform on NVIDIA DGX Spark systems using Docker
Compose.

Everything runs on the box: the web platform, the satellite apps, the model
gateway, and GPU inference. Nothing leaves the network.

## Architecture

`caddy` is the only container publishing ports 80 and 443, so it is the single
front door. Every hostname derives from one setting, `UT_DOMAIN`. Of the four
Docker networks, **three are declared `internal: true`** — the containers that
hold documents, embeddings and model weights have no route off the box, so a
mistake in application code cannot turn into an exfiltration.

Two diagrams and the network membership table: [architecture](docs/architecture.md).
Per-container detail — ports, volumes, how to act on a service:
[the stack](docs/the-stack.md).

## Requirements

- NVIDIA DGX Spark (ARM64) with DGX OS.
- Docker Engine 24.0+ with Compose V2, 250 GB free, 24 GB of RAM.
- NVIDIA Container Toolkit (pre-installed on DGX).
- `avahi-daemon` and `avahi-utils`, for a `.local` address only.
- A registry token for `ghcr.io`, provided by UnderstandTech. It covers the
  NVIDIA NIM inference containers too — they are re-hosted on the
  UnderstandTech registry, so **no NVIDIA NGC account or API key is required on
  the box**.

## Installing

The release is a signed Debian package. Download it, check the signature,
install it, then run the installer:

```bash
sudo apt-get install ./understandtech_<version>_all.deb
sudo ut-install --domain box.example.com
```

`ut-install` writes `/etc/understandtech/.env`, generates every secret, pulls
the images, starts the stack, waits for the platform to be healthy and installs
the boot service. It does not wait for the inference engines, which load their
weights in the background. It is safe to interrupt and safe to re-run.

It prints two secrets **once** at the end — the initial admin password and the
backup password. Losing the backup password makes every snapshot unreadable,
with no recovery path.

Full procedure, including how to verify the signature offline:
[installing](docs/install.md).

## Using it

Every hostname derives from `UT_DOMAIN`, the single setting that names the
appliance. Change it and all six follow.

| Hostname | What it serves |
|---|---|
| `understand.local` | The platform — documents, conversations, the API |
| `llms.understand.local` | Model catalogue and playground |
| `assistants.understand.local` | Assistant builder |
| `admin.understand.local` | Tenant and user administration |
| `builder.understand.local` | App Builder (add-on) |
| `<app>.apps.understand.local` | One per generated app |

- First time on a new box: [first-run configuration](docs/first-run-configuration.md).
- For the people who will use the platform: [using the platform](docs/using-the-platform.md).

## What's in This Repo

| File | Purpose |
|---|---|
| `compose.yaml` | Docker Compose stack — all services, networks, volumes |
| `compose.appbuilder.yaml` | App Builder add-on — enabled by `COMPOSE_FILE` in `.env`, which `release.env` ships switched on |
| `Caddyfile` | Reverse proxy config — one site block per surface, hostnames from `UT_DOMAIN` |
| `caddy/ingress-*.caddy` | One per ingress mode — global options and the `(tls)` snippets |
| `caddy/certs/` | Where a `custom`-mode certificate goes (gitignored) |
| `release.env` | What the release decides — the exact images, model config, defaults. Replaced on every upgrade, and carries no secret |
| `setup-autostart.sh` | Installs the systemd boot service, and the mDNS alias publisher on a `.local` domain only; `--check` validates domain/TLS settings |
| `ut-logs-archive` | Automated daily log archival with compression and retention |
| `ut-certificate` | Obtains and renews a publicly trusted certificate by DNS-01, so nothing has to be installed on user machines |
| `ut-verify` | Checks a package's signature offline, for a machine with no network — `dpkg` verifies nothing on its own |
| `packaging/build-deb.sh` | Builds the Debian package: release in `/usr/share`, settings in `/etc`, data in `/var/lib` |
| `packaging/pin-images.sh` | Rewrites every image in `release.env` as `name:tag@sha256:…`, so a version names one exact image and not whatever the tag points at today. `--check` reports without changing anything |
| `packaging/release-bom.sh` | Writes what a release is made of, as CycloneDX: one component per image, named by digest. Reads `release.env` and nothing else — no registry, no pull |
| `appbuilder/traefik/` | Static routing config for the App Builder's per-app router |
| `test/` | The checks, and what each one exists to catch — see `test/README.md` |

## Documentation

**For the operator**, in the order you will need them:

| | When |
|---|---|
| [Architecture](docs/architecture.md) | Where a request goes, and what each network can reach. |
| [Installing](docs/install.md) | A new machine. One command, safe to re-run. |
| [First-run configuration](docs/first-run-configuration.md) | The first visit to a freshly installed box: models, sign-on, data sources. |
| [The stack](docs/the-stack.md) | What runs, on which network, in which volume, and how to act on it. |
| [Configuring](docs/configuration.md) | Changing the address, the ports, the backup schedule, the load. |
| [Certificates and DNS](docs/certificates-and-dns.md) | Which names to publish, who terminates TLS, and what the local authority does. |
| [Updating](docs/update.md) | A new version. What it adds to an existing `.env`, and what changes that you will notice. |
| [Restoring](docs/restore.md) | The database, the customer's files, or the certificate authority — separately. |
| [When it breaks](docs/when-it-breaks.md) | A symptom, and which layer it belongs to. Start here when something is wrong. |
| [Decommissioning](docs/decommissioning.md) | Taking a machine out of service. What removing the package does **not** remove. |

**For the people who use the platform**:
[using the platform](docs/using-the-platform.md).

**For anyone changing this repository**: [the checks](test/README.md).
