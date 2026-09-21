# The stack

What runs on the box, where it sits, what it stores, and how to act on it.
Read this when something is not healthy, when you need to know whether a port
is reachable, or before deleting anything.

For the shape of the request path and what each network can reach, see
[architecture](architecture.md).

## Services

Only `caddy` publishes ports on every interface. The two NIM containers are
bound to loopback, so they are reachable from the machine itself and from
nowhere else; a compute node that has to serve another machine overrides
`NIM_LLM_BIND_ADDRESS`. **Everything else is reachable only from inside the
Docker networks** — the database has no host port at all.

Five services carry no fixed container name, because a fixed name and `--scale`
are mutually exclusive. Compose names them after the project, so the prefix
follows `COMPOSE_PROJECT_NAME`.

| Service | Container | Host port | Description |
|---|---|---|---|
| `caddy` | `ut-caddy` | 80, 443, 127.0.0.1:8443 | Reverse proxy; public TLS per `UT_INGRESS_MODE`, machine-facing TLS always from the local authority |
| `step-ca` | `ut-step-ca` | — | Local certificate authority. Root under `${DATA_ROOT}/ca`, so the file backup carries it |
| `frontend` | `ut-frontend` | — | React web application |
| `api` | `ut-api` | — | Main backend API (FastAPI), `:8501` internal |
| `api-customer` | `ut-api-customer` | — | Partner (REST v3) API and model gateway, `:8501` internal |
| `workers` | `understandtech-workers-*` | — | RQ background jobs on the `ut-api` queue |
| `workers-customer` | `understandtech-workers-customer-*` | — | RQ background jobs on the `ut-api-partners` queue |
| `app-llms` | `ut-app-llms` | — | Model catalogue and playground, at `llms.<UT_DOMAIN>` |
| `app-assistants` | `ut-app-assistants` | — | Assistant builder, at `assistants.<UT_DOMAIN>` |
| `admin-portal` | `ut-admin-portal` | — | Tenant and user administration, at `admin.<UT_DOMAIN>` |
| `llm` | `understandtech-llm-*` | — | RAG, embeddings and reranking on GPU, `:8000` internal |
| `nim-llm` | `understandtech-nim-llm-*` | 127.0.0.1:8001 | NVIDIA NIM serving the chat model (profile `nim`) |
| `nim-vlm` | `understandtech-nim-vlm-*` | 127.0.0.1:8002 | NVIDIA NIM serving the vision model (profile `nim`) |
| `mongodb` | `ut-mongodb` | — | Document database |
| `redis` | `ut-redis` | — | Task queue and cache |
| `mongodb-backup` | `ut-mongodb-backup` | — | Full-server dump of every database |
| `files-backup` | `ut-files-backup` | — | Encrypted file snapshots, and the offsite copy |
| `app-builder` | `ut-app-builder` | 8011 (`APP_BUILDER_HOST_PORT`) | Builds and hosts generated apps (add-on) |
| `app-builder-traefik` | `ut-app-builder-traefik` | — | Per-app routing for generated apps (add-on) |

`nim-llm` and `nim-vlm` sit behind compose profiles, so they only start when
`COMPOSE_PROFILES` includes `nim` (or `nim-llm` / `nim-vlm` individually).
`release.env` sets `COMPOSE_PROFILES="nim"`.

The worker services scale with `WORKER_REPLICAS` and `WORKER_CUSTOMER_REPLICAS`.

## Networks

The stack declares four bridge networks. **Three of them are `internal: true`**,
which means the containers attached only to those have no route off the box.

| Network | Internal | Who is on it |
|---|---|---|
| `ut-frontend-network` | no | `caddy`, `frontend`, `api`, `api-customer`, the workers, `app-llms`, `app-assistants`, `admin-portal`, `llm` |
| `ut-backend-network` | **yes** | `api`, `api-customer`, the workers, `app-assistants`, `admin-portal`, `llm`, the NIM containers, `redis`, `files-backup` |
| `ut-data-network` | **yes** | `mongodb`, `mongodb-backup`, `api`, `api-customer`, the workers, `app-llms`, `app-assistants`, `llm` |
| `ut-ca-network` | **yes** | `caddy`, `step-ca` |

One more, for the add-on only:

- **`proxy`** (external, App Builder) — shared with the generated apps' own
  compose projects, so no single project owns it. Create it once with
  `docker network create proxy`; `setup-autostart.sh` also creates it if the
  overlay is enabled.

`ut-frontend-network` is the only one that is not internal. That is what lets
`caddy` answer from outside; it is also why a service that must never reach the
internet is kept off it.

## Volumes

| Volume | Purpose |
|---|---|
| `ut-caddy-data` | Caddy TLS certificates and state |
| `ut-caddy-config` | Caddy configuration |
| `ut-redis-data` | Redis AOF persistence |
| `ut-mongodb-data` | MongoDB database files |
| `ut-mongodb-backup` | Compressed backup archives |
| `ut-uploads-data` | Shared upload scratch space (API + workers) |
| `ut-llm-ollama` | Ollama configuration |
| `ut-llm-models` | LLM model files |
| `ut-vllm-models` | Hugging Face cache for the LLM service |
| `ut-vllm-llm-cache` | vLLM compilation cache |
| `ut-nim-llm-cache` | NIM chat-model weights (survives updates — do not prune casually) |
| `ut-nim-vlm-cache` | NIM vision-model weights (idem) |

Every volume carries an explicit `name:`, so the names are fixed rather than
prefixed with the compose project. Data therefore survives a project rename or
a move to a different directory.

The trade-off is that compose warns if a volume was originally created under a
different project name:

```text
WARN volume "ut-mongodb-data" already exists but was created for project "ut"
     (expected "understandtech")
```

That is a label mismatch, not a data problem — compose still mounts the right
volume, and the stack runs normally. It means the volume was created by a
compose run whose project name was not `understandtech`; the usual cause is a
run from a directory of another name, an explicit `-p`, or volumes copied in
from another machine. Check with:

```bash
docker volume ls -q | while read -r v; do
  printf '%-28s %-18s %s\n' "$v" \
    "$(docker volume inspect -f '{{index .Labels "com.docker.compose.project"}}' "$v")" \
    "$(docker volume inspect -f '{{.CreatedAt}}' "$v")"
done
```

Do not "fix" it by marking the volumes `external: true` — compose would then
refuse to create them, breaking every fresh install. Either leave the warning
alone, or, on a box with no data worth keeping, stop the stack and delete the
mislabelled volumes so compose recreates them cleanly. Deleting
`ut-mongodb-data` destroys the database and deleting `ut-nim-*-cache` forces a
full model re-download, so check what is in them first.

Two host paths are bind-mounted rather than kept in volumes:

| Host path | Mounted by | Purpose |
|---|---|---|
| `/var/lib/understandtech/app-data` | `api`, `api-customer`, both worker sets, `app-assistants`, `llm` | Uploaded documents and generated artefacts (`/app/storage`) |
| `/var/lib/understandtech/appbuilder` | `app-builder`, `app-builder-traefik` | `workspaces/`, `prod-workspaces/`, `traefik-dynamic/` |

The App Builder's projects live on the host because it starts each generated app
as its own compose project, and the docker daemon has to be able to resolve
those paths. `setup-autostart.sh` creates both trees.

**`/var/lib/understandtech` is what a backup must cover.** The rest is
reinstallable in a minute. What the backup services do with it is in
[restoring](restore.md).

## Common operations

Run these from the release directory, `/usr/share/understandtech`. Compose
reads `.env` from there for both interpolation and its own settings —
`COMPOSE_FILE` (which overlays the App Builder) and `COMPOSE_PROFILES` (which
enables the NIM containers) are set there.

```bash
# What is running, and is it healthy
docker compose ps

# Follow one service
docker compose logs -f api
docker compose logs -f llm

# Restart one service
docker compose restart api

# Add background capacity
docker compose up -d --scale workers=4

# Install log archival
./ut-logs-archive --install
```

To move to a new version, use [updating](update.md) rather than a bare
`docker compose pull` — the procedure backs up first and tells you what an
upgrade does to your settings.

## Auto-start on boot

`setup-autostart.sh` installs two systemd units and nothing else:

- **`understandtech.service`** — runs `docker compose up -d` in the install
  directory at boot;
- **`ut-mdns-alias.service`** — publishes the apex, satellite and
  generated-app hostnames over mDNS, all derived from `UT_DOMAIN`.

It does not pull images, create stack resources, or start anything. `ut-install`
runs it for you; you only need it directly when changing the domain or
repairing an install.

```bash
# Install both, using this directory as the install directory
sudo ./setup-autostart.sh

# Publish only the mDNS names
sudo ./setup-autostart.sh --mdns

# Status of both units plus every compose service
sudo ./setup-autostart.sh --status

# Check domain and TLS settings, install nothing
sudo ./setup-autostart.sh --check

# Remove
sudo ./setup-autostart.sh --uninstall
```

Re-running it is a no-op: files are compared before being replaced, and the
publisher is only bounced when its config actually changed or it is not
running.

The boot service starts from local images only (`up -d --pull never`). An
offline or air-gapped box therefore still comes up, and boot never stalls on a
registry timeout. It also keeps the boot path away from a credential trap: the
unit runs as root, but `docker login ghcr.io` runs without sudo, so root's
credential store has no `ghcr.io` entry and any pull it attempted would fail on
the private images. Pull as your normal user before the first
`docker compose up -d`, and after every image change.

The service unit sets `WorkingDirectory` and lets `docker compose` read `.env`
itself. It deliberately does not use `EnvironmentFile`: systemd's parser strips
quotes that compose keeps, and anything systemd exported would take precedence
over `.env`, so the stack would boot with different values than a manual
`docker compose up -d` produces.

`/etc/default/ut-mdns-alias` holds the mDNS knobs. It is created once and never
overwritten, so edits there survive re-running the installer. Setting
`UT_MDNS_ALIASES` pins a literal list instead, which then stops following
`UT_DOMAIN` — installs predating this release have exactly that, so the
installer warns when a pinned list no longer mentions the configured domain.
Comment the line out to go back to derivation.

mDNS publishing needs avahi. If it is missing the installer says so and leaves
the unit enabled but stopped:

```bash
sudo apt-get install -y avahi-daemon avahi-utils
sudo systemctl start ut-mdns-alias
```

## App Builder add-on

Lets users describe an app and have it built, then serves the result on the same
box. It runs in the same compose project as everything else and talks to
`api-customer` for models and UT API v3 — nothing leaves the network.

The overlay is already enabled in `release.env`:

```bash
COMPOSE_FILE="compose.yaml:compose.appbuilder.yaml"
```

Comment that line out to run without the App Builder. Otherwise set the gateway
key — the platform UI issues it under **Developer → API keys**:

```bash
APP_BUILDER_GATEWAY_API_KEY="..."
```

The generated apps attach to an external network that no single compose project
owns, so it has to exist before the stack starts:

```bash
docker network create proxy
docker compose up -d
sudo ./setup-autostart.sh --mdns
```

The builder is at `https://builder.<UT_DOMAIN>`; each generated app gets
`https://<project>.apps.<UT_DOMAIN>` plus `--staging` and `--prod` surfaces.
Caddy serves them from a single wildcard site, so no config change is needed per
app. On a `.local` address the alias service rescans the App Builder's traefik
directory every 10 seconds, so a new app resolves within about that long; on
your own domain a single `*.apps.<UT_DOMAIN>` record covers them all.

`APP_BUILDER_HOST_PORT` is published on the host because generated apps run in
their own compose projects and reach the builder's model proxy at
`host.docker.internal:<port>` — docker DNS cannot get them there.

## Running two appliances

Two boxes on the same network need two distinct `UT_DOMAIN` values — otherwise
both publish the same mDNS name and clients reach whichever answers first. That
is the whole change:

```bash
# box 1
UT_DOMAIN="understand.local"

# box 2
UT_DOMAIN="lab.local"
```

Each then serves its own `https://lab.local`, `https://llms.lab.local`, and so
on. The box's own host name no longer has to match: the alias service publishes
the apex itself, skipping it only when avahi already answers for that name
because the host name happens to equal the domain.

They are independent instances with no shared state, so give each its own
`JWT_SECRET`, `STATE_SECRET` and MongoDB credentials.

> **One host, two stacks is not supported.** Running two copies of the stack on
> the same machine needs more than a second domain: the fixed container names,
> the fixed volume `name:` entries, the published host ports (80, 443, 8001,
> 8002, 8011), the single external `proxy` network, the
> `/var/lib/understandtech` host paths, `ut-logs-archive`'s `COMPOSE_PROJECT`
> and the systemd unit names would all collide. Use two boxes.
