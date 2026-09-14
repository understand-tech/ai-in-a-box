# Configuration

Everything is in one file: `/opt/understandtech/.env`. `compose.yaml` reads it
and nothing else.

```bash
cd /opt/understandtech
sudo nano .env
docker compose up -d
```

`up -d` recreates only the containers whose configuration changed. It is not a
restart of the appliance.

## The four kinds of variable

Knowing which kind you are editing matters more than knowing the variable.

**Generated at install, never edited.** `JWT_SECRET`, `STATE_SECRET`,
`OPENID_SECRET_KEY`, `ADMIN_SETUP_PASSWORD`, `BACKUP_FILES_PASSWORD`,
`CA_PASSWORD`, and the MongoDB credentials. Changing one after the fact breaks
something: rotating `MONGODB_PASSWORD` on a database that already exists locks
every service out, because the image only reads it when it creates the data
directory.

**Required.** Five of them make the stack refuse to start if absent — rather
than start misconfigured. An empty `MONGODB_PASSWORD` does not mean "no
password", it means **MongoDB with no authentication at all**.

**Yours to set.** The address, the TLS mode, the ports, the backup schedule and
destination, the number of workers.

**Derived, and overridable.** Every public URL derives from `UT_DOMAIN`. An
explicit value beats the derived one, which is why an old `.env` keeps working
untouched. Leave them alone unless something genuinely sits at a different
address.

## The secrets

`ut-install` generates them. If you are filling `.env` by hand, all of them at
once:

```bash
for k in MONGODB_USERNAME MONGODB_PASSWORD JWT_SECRET \
         STATE_SECRET OPENID_SECRET_KEY ADMIN_SETUP_PASSWORD \
         GPU_VM_API_TOKEN BACKUP_FILES_PASSWORD CA_PASSWORD; do
    sed -i "s|^${k}=.*|${k}=\"$(openssl rand -hex 24)\"|" .env
done
```

**Hexadecimal on purpose.** The database URI is built by concatenation, so a
value holding `@`, `/`, `#` or `%` breaks the connection string.

**Two of them cannot be rotated afterwards.**

`MONGODB_PASSWORD` is only read when the database is first created. Changing it
later changes nothing in the database and stops every service from connecting.

`BACKUP_FILES_PASSWORD` encrypts the backup repository. Losing it makes every
snapshot unreadable — including the offsite copies, including the certificate
authority's root. **Write it down somewhere other than this machine**, because
the offsite copy is exactly what you reach for when this machine is gone.

`JWT_SECRET` is shared by four services, so a token minted at one customer
would be accepted at another if the value were the same. That is why nothing
ships with a value.

## The App Builder

Off by default, and **it cannot be enabled on a first install**: its gateway key
is generated inside the platform, which has to be running first. Enabling it
before that leaves the key empty.

Once the platform is up:

1. In the platform UI, **DEVELOPER → API keys**, create one.
2. Set `APP_BUILDER_GATEWAY_API_KEY` in `.env`.
3. `docker network create proxy`
4. Uncomment `COMPOSE_FILE`.
5. `docker compose up -d`

Step 3 is not optional. The overlay declares that network `external`, generated
apps join it from their own compose projects, so no project owns it and compose
refuses to start without it.

## Inference

`LLM_BACKEND` decides which model is actually served:

| | What takes effect |
|---|---|
| `LLM_BACKEND="nim"` (default) | `NIM_LLM_MODEL_PATH` |
| `LLM_BACKEND="vllm"` | `VLLM_LLM_MODEL` |

So editing `VLLM_LLM_MODEL` on a default install changes nothing.

`VLLM_API_KEY="EMPTY"` is vLLM's convention for **no authentication**, not a
placeholder waiting to be filled. Turning authentication on means setting a real
key *and* passing `--api-key` through `NIM_LLM_PASSTHROUGH_ARGS`. Until then,
keep the engines on loopback.

`GATEWAY_MODELS` lists what the catalogue offers. **Local models only**: an entry
with an external `base_url` sends prompts off the appliance, which is the one
thing this product promises not to do.

`HF_HUB_OFFLINE="0"` lets containers fetch model weights on first start — which
is why an appliance sold as offline is only offline after a connected first
boot. Setting it to `1` requires the weights to be present already.

## What you will actually change

### The address

```bash
UT_DOMAIN="box.example.com"
```

The only place the name is written. See
[certificates and DNS](certificates-and-dns.md) — six names to publish.

### How TLS is terminated

```bash
UT_INGRESS_MODE="internal"   # or custom, or edge
```

Same document. In `edge` mode, three other variables go with it.

### Where the data lives

```bash
DATA_ROOT="/var/lib/understandtech"
```

Documents, and the certificate authority's root. This is what the file backup
covers. Moving it means moving the contents too — nothing does it for you.

### Backups

```bash
BACKUP_BEGIN="1520"            # HHMM, local time
BACKUP_INTERVAL="1440"         # minutes
BACKUP_FILES_KEEP_DAILY="7"
BACKUP_FILES_KEEP_WEEKLY="4"
BACKUP_FILES_KEEP_MONTHLY="6"
```

And the destination, which defaults to this machine:

```bash
BACKUP_FILES_REPOSITORY="s3:s3.amazonaws.com/bucket/path"
BACKUP_FILES_S3_KEY_ID="..."
BACKUP_FILES_S3_SECRET="..."
```

**The default keeps everything on the machine it protects** — the `restic`
repository sits in the same volume as the database archives. Against a disk
failure or a theft, that is no protection at all.

### Load

```bash
WORKER_REPLICAS="2"
WORKER_CUSTOMER_REPLICAS="2"
```

Background document processing. More replicas, more parallel ingestion, more
memory.

### Verbosity

```bash
LOG_LEVEL="INFO"
```

`DEBUG` puts document content in the logs. It was the shipped default for a
long time — if this appliance was installed before that changed, it is still
`DEBUG` in your file and no update touches it, because an explicit value always
wins.

## Running more than one stack on a machine

Five variables make a stack independent of anything else on the machine:

```bash
COMPOSE_PROJECT_NAME="staging"
RESOURCE_PREFIX="staging"
CONTAINER_PREFIX="staging"
DATA_ROOT="/var/lib/understandtech-staging"
MONGODB_HOST_PORT="27118"
```

`COMPOSE_PROJECT_NAME` is not redundant. Three services carry no fixed container
name, and Compose names those after the project: setting only the prefixes
leaves them colliding with the other stack.

Add `UT_HTTP_PORT` and `UT_HTTPS_PORT` if the first stack already holds 80 and
443.

## Opening inference to another machine

The inference engines listen on `127.0.0.1` only. They have **no
authentication** — `VLLM_API_KEY="EMPTY"` is vLLM's convention for "none", not a
field waiting to be filled — so opening them is a deliberate act, named by an
interface:

```bash
NIM_LLM_BIND_ADDRESS="10.42.0.7"
NIM_VLM_BIND_ADDRESS="10.42.0.7"
```

Required on a compute node, which exists to serve another machine and would
otherwise start, pass its healthcheck and serve nobody. Never on a single-box
install.

## What to check after editing

```bash
docker compose config >/dev/null && echo "the file parses"
docker compose up -d
docker compose ps
```

`docker compose config` catches a missing required variable before anything
restarts. It does not catch a typo in `UT_INGRESS_MODE`: docker would create a
directory where the missing fragment should be. `sudo ./ut-install --check`
catches that one.

## Where it can go wrong

**The stack will not start after an edit.** Almost always a required variable
emptied. The error names it.

**A service restarts in a loop.** `docker compose logs <service>` — usually a
URL pointing at an address that no longer resolves.

**Users are signed out after changing the address.** Expected: the OIDC redirect
URI derives from `UT_DOMAIN`.

**The browser warns again.** The certificate no longer matches the name, or the
authority changed. See [certificates and DNS](certificates-and-dns.md).
