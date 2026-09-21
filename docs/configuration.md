# Configuration

For the operator changing a setting on an appliance that is already installed.
After reading you will know which file to edit, which of the four kinds of
variable you are touching, and what to run to make the change take effect.

Installing a new machine is [installing](install.md). Moving to a new version
is [updating](update.md).

`compose.yaml` reads one file and nothing else: `.env`. But `.env` is **built**,
not kept — the installer writes it from what the release decides and from what
you chose, and rebuilds it every time it runs. Editing it directly means losing
the edit at the next update.

**What you edit is `/etc/understandtech/local.env`.** It is yours, no upgrade
replaces it, and every value in it wins over the release's.

```bash
sudo nano /etc/understandtech/local.env
sudo ut-install --skip-pull
docker compose up -d
```

`ut-install` is what turns your edit into `.env`. Running it with `--skip-pull`
does that without downloading anything.

`up -d` recreates only the containers whose configuration changed. It is not a
restart of the appliance.

## The four kinds of variable

Knowing which kind you are editing matters more than knowing the variable.

**Generated at install, never edited.** `JWT_SECRET`, `STATE_SECRET`,
`OPENID_SECRET_KEY`, `ADMIN_SETUP_PASSWORD`, `BACKUP_FILES_PASSWORD`,
`CA_PASSWORD`, `GPU_VM_API_TOKEN`, and the MongoDB credentials. Changing one
after the fact breaks something: rotating `MONGODB_PASSWORD` on a database that
already exists locks every service out, because the image only reads it when it
creates the data directory.

**Required.** Seven of them make the stack refuse to start when absent **or
empty** — rather than start misconfigured: `MONGODB_USERNAME`,
`MONGODB_PASSWORD`, `JWT_SECRET`, `STATE_SECRET`, `CA_PASSWORD`,
`GPU_VM_API_TOKEN` and `BACKUP_FILES_PASSWORD`.

That refusal is the point for `MONGODB_PASSWORD` above all. An empty value
would not mean "no password", it would mean **MongoDB with no authentication at
all** — so compose stops before the container is created rather than let that
happen.

**Yours to set.** The address, the TLS mode, the ports, the backup schedule and
destination, the number of workers.

**Derived, and overridable.** Every public URL derives from `UT_DOMAIN`. An
explicit value beats the derived one, which is why an old `.env` keeps working
untouched. Leave them alone unless something genuinely sits at a different
address.

## The secrets

`ut-install` generates them. If you are filling `local.env` by hand, all of them at
once:

```bash
for k in MONGODB_USERNAME MONGODB_PASSWORD JWT_SECRET \
         STATE_SECRET OPENID_SECRET_KEY ADMIN_SETUP_PASSWORD \
         GPU_VM_API_TOKEN BACKUP_FILES_PASSWORD CA_PASSWORD; do
    sed -i "s|^${k}=.*|${k}=\"$(openssl rand -hex 24)\"|" /etc/understandtech/local.env
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
2. Set `APP_BUILDER_GATEWAY_API_KEY` in `local.env`.
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
BACKUP_BEGIN="+0"              # at startup; an HHMM value waits for that hour
BACKUP_INTERVAL="1440"         # minutes
BACKUP_FILES_KEEP_DAILY="7"
BACKUP_FILES_KEEP_WEEKLY="4"
BACKUP_FILES_KEEP_MONTHLY="6"
```

### Sending backups off the machine

**The default keeps everything on the machine it protects** — the `restic`
repository sits in the same volume as the database archives. Against a disk
failure, a theft or a fire, that is no protection at all.

Three settings change it:

```bash
BACKUP_FILES_REPOSITORY="s3:https://s3.eu-west-3.amazonaws.com/your-bucket/appliance"
BACKUP_FILES_S3_KEY_ID="AKIA..."
BACKUP_FILES_S3_SECRET="..."
```

Any S3-compatible endpoint works — AWS, MinIO, Scaleway, OVH. For SFTP instead,
give `BACKUP_FILES_REPOSITORY="sftp:user@host:/path"` and put the key where the
container can read it.

```bash
docker compose up -d files-backup
docker compose logs -f files-backup
```

The first run initialises the repository and uploads everything; later runs send
only what changed. Check it arrived:

```bash
docker exec ut-files-backup restic snapshots
```

**Keep `BACKUP_FILES_PASSWORD` somewhere else than the machine.** It encrypts
the repository, so a remote copy is worth nothing without it — and a remote copy
is exactly what you reach for when the machine is gone.

What this covers, verified end to end on every push by
`backups_reach_an_offsite_destination`: the documents, and the certificate
authority's root, backed up to an S3 endpoint and restored from that endpoint
alone, path by path and checksum by checksum.

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

## When the first install is slow to download

A first install pulls about **21 GB**. The inference container is 10.7 GB of
that, the model gateway 6.3 GB, and the other eight services share the rest.
None of it is configurable — it is what the release is made of, and the
`.cdx.json` published beside the package lists every image with its digest.

Docker fetches **three layers at a time** by default. On a link that is not
already saturated, raising that shortens the pull:

```bash
sudo tee /etc/docker/daemon.json >/dev/null <<'EOF'
{ "max-concurrent-downloads": 8 }
EOF
sudo systemctl restart docker
```

Three things to know before doing it.

**The restart stops every container on the machine**, a running stack included.
Do it before the first install, or accept the interruption.

**`/etc/docker/daemon.json` is shared.** The address-pool settings in
[starting states](starting-states.md) live in the same file, and so does
anything else on the machine that configures Docker. If the file already exists,
add the key to it rather than replacing it.

**And it may buy nothing.** Of the 116 distinct layers a first install fetches,
93 are under 50 MB and **two carry 4.6 GB between them**. Concurrency helps when
many medium layers queue behind the limit; it does not make a 2.7 GB layer
arrive faster. Time the pull before and after rather than assume.

An install that has to be quick on a slow link is a different problem:
`ut-install --skip-pull` starts a stack whose images are already on the machine,
which is how an air-gapped site works. Getting them there is not something this
file can arrange.

## Running more than one stack on a machine

Five variables make a stack independent of anything else on the machine:

```bash
COMPOSE_PROJECT_NAME="staging"
RESOURCE_PREFIX="staging"
CONTAINER_PREFIX="staging"
DATA_ROOT="/var/lib/understandtech-staging"
MONGODB_HOST_PORT="27118"
```

`COMPOSE_PROJECT_NAME` is not redundant. Five services carry no fixed container
name — `workers`, `workers-customer`, `llm`, `nim-llm` and `nim-vlm`, because a
fixed name and `--scale` are mutually exclusive. Compose names those after the
project, so setting only the prefixes leaves them colliding with the other
stack.

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
directory where the missing fragment should be. **`sudo ./setup-autostart.sh --check`
is what catches that one** — `ut-install --check` does not look at the ingress
settings at all.

## Where it can go wrong

The four failures that follow an edit, with what they mean, are in
[when it breaks](when-it-breaks.md#after-changing-a-setting): a stack that will
not start, a service restarting in a loop, users signed out, and the browser
warning again.

## What this document does not cover

**The first configuration of a new box** — the models, sign-on and data sources
you set from the browser rather than from `local.env`. That is
[first-run configuration](first-run-configuration.md), and none of it lives in
`.env`.

**What an upgrade does to the settings you have.** `ut-install` re-builds `.env`
on every run, and [updating](update.md) is where that mechanism is explained in
full — this page assumes it and does not repeat it.

**Which TLS mode to choose.** The variable is listed here; the decision, and
what each mode costs you, is [certificates and DNS](certificates-and-dns.md).

**What each service does with a setting.** See [the stack](the-stack.md).
