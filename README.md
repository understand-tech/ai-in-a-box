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
- A license key, provided by UnderstandTech. It carries the access to the
  `ghcr.io` registry, which covers the NVIDIA NIM inference containers too — they are re-hosted on the
  UnderstandTech registry, so **no NVIDIA NGC account or API key is required on
  the box**.

## Installing

The release is a signed Debian package. `ut-get` downloads it, checks the
signature, installs it, then runs the installer:

```bash
curl -fsSLO https://github.com/understand-tech/ai-in-a-box/releases/download/v<version>/ut-get
sudo bash ut-get --version <version> --domain box.example.com
```

`ut-install` writes `/etc/understandtech/.env`, generates every secret, pulls
the images, starts the stack, waits for the platform to be healthy and installs
the boot service. It does not wait for the inference engines, which load their
weights in the background, nor for the backup: a backup that is not working yet
is named at the end, with its reason. It is safe to interrupt and safe to re-run.

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
| `ut-get` | Installs a release in one command: downloads the latest one, or `--version <version>`, into `/var/cache/understandtech/releases` and resumes a download that stopped — or takes one carried in by hand with `--from <directory>`. Checks the package's signature with the key `ut-verify` carries, installs it with `apt-get`, then runs `ut-install` with every other option. Installs nothing it could not verify |
| `ut-report` | Writes how loaded the engines were and how many people they served, hour by hour, for the operator to pass on. Sends nothing |
| `ut-send`, `cmd/ut-send/` | Keeps whether this machine's operator agreed to send its usage reports, and where to (`ut-send configure`, asked by `ut-install`). `ut-send collect report` puts in line `ut-report`'s report with the health of the stack and the use of each tool, `ut-send collect usage` what the recorder kept since the last export, the customer's domain replaced by the surface it names; `ut-send send` delivers what is in line and keeps what the receiver did not take, for up to 7 days; `ut-send tick` does all three, run by the `ut-send.timer` a yes installs, every 15 minutes or as `--every` says. Written in Go, standard library only: `go vet ./... && go test ./...` |
| `ut-setup`, `cmd/ut-setup/` | Installs from a browser on the box: serves a page on 127.0.0.1, behind a code that works once, that asks what `ut-install` asks, runs it, follows it, and shows the two passwords once. `ut-get --browser` ends there. Written in Go, standard library only |
| `metrics/prometheus.yml` | What the `metrics` service keeps of the engines' counters, and of the gateway's and the LLM service's per-request measures |
| `packaging/build-deb.sh` | Builds the Debian package: release in `/usr/share`, settings in `/etc`, data in `/var/lib` |
| `packaging/build-ut-send.sh` | Compiles the Go tools, `ut-send` and `ut-setup`, for arm64 and amd64, the same bytes every time; run it before `packaging/build-deb.sh` |
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
| [The usage report](docs/usage-report.md) | We ask for one. What it holds, what it never holds, and how to write it. |

**For the people who use the platform**:
[using the platform](docs/using-the-platform.md).

**For anyone changing this repository**: [the checks](test/README.md).
