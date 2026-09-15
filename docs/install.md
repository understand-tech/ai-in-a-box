# Installing

One command. It is safe to interrupt and safe to re-run: every step checks its
own state before acting, so an install that stopped halfway is resumed by
running the same command again.

## What you need first

- A machine with Docker 24 or newer and Compose v2, 250 GB free, 24 GB of RAM.
- A registry token for `ghcr.io`.
- The address the appliance will answer on. Not `understand.local` unless the
  machine really is on a flat local network — see
  [certificates and DNS](certificates-and-dns.md).

## Check before you touch anything

```bash
sudo ./ut-install --check
```

Changes nothing. It reports Docker's version, whether the GPU is reachable from
containers, free disk, RAM, and whether the address resolves. Read it before
going further: every problem it names is one you would otherwise hit halfway
through, with services already running.

The GPU check accepts either mechanism — the legacy `nvidia` docker runtime, or
CDI device files under `/etc/cdi` and `/var/run/cdi`. Recent NVIDIA toolkits
register no docker runtime at all, so a working machine can have none.

## Install

```bash
sudo ./ut-install --domain box.example.com
```

It will ask for the registry token, or read it from `--token-file`, or take it
from `UT_REGISTRY_TOKEN`. It is never passed on a command line and never written
to the log.

**Leave `--domain` out and it asks.** On a first install, answering nothing
takes `understand.local`, which resolves over mDNS on one flat network and
nowhere else, and which no public authority will certify — so every machine that
uses the appliance then has to install its root by hand. An unattended install
with no terminal to ask on takes the same fallback and says so in the log.

On a machine that is already configured it offers the address that machine
answers on, and answering nothing keeps it. Re-running the installer never
changes the address by itself.

A real domain is what removes that, and it also decides what the installer sets
up: the mDNS publisher is installed only for a `.local` address. On your own
domain nothing is published here and Avahi is not needed — the six names come
from your zone.

What it does, in order: fetches the repository, writes `.env`, **generates every
secret**, checks the address resolves, prepares the certificate authority
directory, creates the App Builder network, pulls the images, starts the stack,
waits for every service to be healthy, applies the certificate policy, and
installs the boot service.

Allow up to 45 minutes on a first install: the inference engines download and
load their model weights.

## Write down what it prints at the end

Two secrets are shown **once**, on the terminal and not in the log:

- the **initial admin password**;
- the **backup password** (`BACKUP_FILES_PASSWORD`).

Losing the backup password makes every snapshot unreadable — including the
remote ones, including the certificate authority's root. There is no recovery
path. Put it wherever your organisation keeps such things before closing the
terminal.

## Verify

```bash
cd /opt/understandtech
docker compose ps
```

Every service should read `healthy`. Then open `https://<your-domain>` and sign
in with the admin password.

In the default TLS mode the browser warns on first visit: the certificate is
signed by an authority only this machine knows. That is expected — see
[certificates and DNS](certificates-and-dns.md) to make the warning go away.

## Useful options

| Option | When |
|---|---|
| `--check` | Before anything. Changes nothing. |
| `--dir PATH` | Install somewhere other than `/opt/understandtech`. |
| `--domain NAME` | The address the platform answers on. Asked for when omitted. |
| `--token-file PATH` | Read the registry token from a file instead of a prompt. |
| `--skip-pull` | Images are already on the machine — an air-gapped install. |
| `--no-autostart` | Do not install the boot service. |
| `--health-timeout N` | Longer than 3600 s if the machine is slow to load models. |

## If it stops

It says which step and which line. Nothing is rolled back, and the same command
resumes from there. The full log is at `/var/log/ut-install.log`.

The two failures worth knowing in advance:

**The GPU is not reachable from containers.** The preflight says so. Install the
NVIDIA container toolkit, then re-run.

**The address does not resolve.** The appliance starts, but nothing reaches it
by name. Either add the DNS records — six names, see
[certificates and DNS](certificates-and-dns.md) — or re-run with a `--domain`
that resolves.

## Installing beside something else

More than one stack on one machine — a test install next to a live one — needs
its own names, its own directory and its own ports:

```bash
COMPOSE_PROJECT_NAME=staging RESOURCE_PREFIX=staging CONTAINER_PREFIX=staging \
DATA_ROOT=/var/lib/understandtech-staging MONGODB_HOST_PORT=27118 \
UT_HTTP_PORT=8080 UT_HTTPS_PORT=8443 \
  docker compose up -d
```

`COMPOSE_PROJECT_NAME` is not optional here: three services carry no fixed
container name, and Compose names those after the project. Setting only the
prefixes leaves them colliding.
