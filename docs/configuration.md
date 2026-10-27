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
`GPU_VM_API_TOKEN`, `GATEWAY_METRICS_TOKEN`,
`APP_BUILDER_TOKEN_ENCRYPTION_KEY`, and the MongoDB credentials. Changing one
after the fact breaks something: rotating `MONGODB_PASSWORD` on a database that
already exists locks every service out, because the image only reads it when it
creates the data directory.

**Required.** Six of them make the stack refuse to start when absent **or
empty** — rather than start misconfigured: `MONGODB_USERNAME`,
`MONGODB_PASSWORD`, `JWT_SECRET`, `STATE_SECRET`,
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
         GPU_VM_API_TOKEN BACKUP_FILES_PASSWORD GATEWAY_METRICS_TOKEN; do
    sed -i "s|^${k}=.*|${k}=\"$(openssl rand -hex 24)\"|" /etc/understandtech/local.env
done
```

**Hexadecimal on purpose.** The database URI is built by concatenation, so a
value holding `@`, `/`, `#` or `%` breaks the connection string.

`APP_BUILDER_TOKEN_ENCRYPTION_KEY` is the exception. The App Builder reads it
with Fernet, which takes 32 random bytes in URL-safe base64 and refuses
hexadecimal:

```bash
sed -i "s|^APP_BUILDER_TOKEN_ENCRYPTION_KEY=.*|APP_BUILDER_TOKEN_ENCRYPTION_KEY=\"$(openssl rand -base64 32 | tr '+/' '-_')\"|" /etc/understandtech/local.env
```

**Three of them cannot be rotated afterwards.**

`MONGODB_PASSWORD` is only read when the database is first created. Changing it
later changes nothing in the database and stops every service from connecting.

`BACKUP_FILES_PASSWORD` encrypts the backup repository. Losing it makes every
snapshot unreadable — including the offsite copies, including the certificate
authority's root. **Write it down somewhere other than this machine**, because
the offsite copy is exactly what you reach for when this machine is gone.

`APP_BUILDER_TOKEN_ENCRYPTION_KEY` encrypts the GitLab tokens the App Builder
stores. Changing it makes every stored connection unreadable, and every user has
to connect GitLab again.

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

### Pushing apps to GitLab

The App Builder can push each generated app's code to a GitLab repository, in
two ways. Each one stays hidden while its settings are empty.

**With a personal access token**, on by default. Users paste the address of
their GitLab and a token with the `api` scope. The App Builder stores the token
encrypted with `APP_BUILDER_TOKEN_ENCRYPTION_KEY`, which `ut-install` generates.

**A GitLab on your own network is refused until you name it.** The App Builder
only contacts hosts that resolve to public addresses, except the ones listed
here — and once the list is set, those are the only ones it contacts:

```bash
APP_BUILDER_GITLAB_ALLOWED_HOSTS="gitlab.example.internal,git.example.com"
```

**With one click, on gitlab.com only.** Register a confidential application in
gitlab.com (**Settings → Applications**) with the `api` and `read_user` scopes
and `https://builder.<UT_DOMAIN>/api/gitlab/auth/callback` as its redirect URI,
then:

```bash
APP_BUILDER_GITLAB_CLIENT_ID="…"
APP_BUILDER_GITLAB_CLIENT_SECRET="…"
```

The appliance has to reach gitlab.com for this one. Set
`APP_BUILDER_GITLAB_REDIRECT_URI` only if GitLab has to call back another
address.

### Build progress

```bash
APP_BUILDER_LLM_STREAMING=""
APP_BUILDER_PROGRESS_WAIT_SECS=""
```

The App Builder streams the model's answer: that is what shows the file being
written, and what says *Waiting for capacity* when no first token has come after
`APP_BUILDER_PROGRESS_WAIT_SECS` seconds, 15 when empty. `"0"` in
`APP_BUILDER_LLM_STREAMING` goes back to whole answers, and that message goes
with it.

## Inference

`LLM_BACKEND` decides which model is actually served:

| | What takes effect |
|---|---|
| `LLM_BACKEND="nim"` (default) | `NIM_LLM_MODEL_PATH` |
| `LLM_BACKEND="vllm"` | `VLLM_LLM_MODEL` |

So editing `VLLM_LLM_MODEL` on a default install changes nothing.

The same model reads images: `VLLM_VLM_MODEL`, `GATEWAY_VLM_MODEL` and the
`uai-vision` entry of `GATEWAY_MODELS` carry its name, and `VLLM_VLM_BASE_URL`
points at `nim-llm`. Changing the model means changing all of them, since
`nim-llm` only answers to the name it serves.

### Choosing the model

Rather than editing those names one by one, give the install one of the models
in `models/`:

```bash
sudo ut-install --model qwen3.8-27b-nvfp4
```

`ut-install --list-models` prints the models this machine can serve, one a line:
the name `--model` takes, the engine, the size of the weights, the license, and
`runs code of its own` when the engine loads code from the model's repository. The
models not proven on this GPU are named after them.

```text
nemotron-3.5-bolt-74b        vLLM on gb10                       25.1 GB    OpenMDW-1.1    runs code of its own
qwen3.8-27b-nvfp4            NIM on gb10                        26.4 GB    apache-2.0
```

Each file there is one model: its license (`MODEL_LICENSE`), the names the platform asks it by, and one or two
**variants**, NIM (`NIM_IMAGE`, `NIM_LLM_MODEL_PATH`, `NIM_LLM_PASSTHROUGH_ARGS`) or
vLLM (`VLLM_ENGINE_IMAGE`, `VLLM_ENGINE_MODEL`, `VLLM_ENGINE_ARGS`), each image
pinned by digest.

A variant is only used on a GPU it has been **proven** on: a file
`models/proven/<model>.<nim|vllm>.<family>.md` records the trial, and names the
image it was made with. The family is the GPU's name without the vendor, `gb10` for
an NVIDIA GB10. The install takes the NIM variant when it is proven on this machine,
else the vLLM one, and says which. `--engine nim` or `--engine vllm` asks for one;
it is still taken only if proven here. When neither is, the install stops and lists
the models proven on this GPU.

On vLLM it adds `compose.engine-vllm.yaml`, which runs the engine from
`VLLM_ENGINE_IMAGE` as `vllm serve <VLLM_ENGINE_MODEL> --served-model-name
<VLLM_ENGINE_MODEL> <VLLM_ENGINE_ARGS>`, under the same service name, GPU, port and
cache. The served name stays the model's even offline, where vLLM would otherwise
serve it under its local path. A machine that starts no engine of its own,
installed with `--no-gpu` or `--inference-from`, takes the model's names only.

The model is kept by name, as `UT_MODEL` in `local.env`, and its entry is applied
again on every install: a release that moves a model to a new engine version
reaches the boxes that chose it.

`VLLM_ENGINE_ARGS` is split on spaces: a JSON argument goes in bare, with no space
inside and no quotes around it.

`LLM_FILE_TOKEN_BUDGET` caps the text of files attached to a chat — a PDF, a
spreadsheet — at 16000 tokens by default. Past it, the upload is refused with
the count and the limit. Raising it lets longer documents through, at the cost
of slower answers: keep it under `--max-model-len` minus 40% of
`LLM_MAX_CONTEXT_LEN`, which is held for the answer, minus about 10000 for the
prompt. With this release's values, 56000.

`VLLM_API_KEY` is generated by `ut-install`, and the platform sends it with
every request to the engine. The engine does not check it itself — NIM refuses
a key of its own — so it stays on loopback. On a platform paired with a compute
node, the platform's own Caddy checks it before carrying the request to the
node; it never leaves the platform. See
[opening inference to another machine](#opening-inference-to-another-machine).

`GATEWAY_MODELS` lists what the catalogue offers. **Local models only**: an entry
with an external `base_url` sends prompts off the appliance, which is the one
thing this product promises not to do.

`HF_HUB_OFFLINE` is set to `1` by `ut-install` once it has placed the weights
the release pins, downloaded or from a prepared folder: no container fetches a
model on its first start. It stays `0` only after an install with `--skip-pull`,
which places none.

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

Documents. This is what the file backup covers. Moving it means moving the
contents too — nothing does it for you.

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

#### To a disk the host mounts

A share of your NAS, or a USB disk. The backup service gains a directory, never
a network: whatever carries the bytes off the machine is the host's business.

Mount it the way your systems usually are — an `/etc/fstab` line or a systemd
mount unit — so that it comes back after a reboot. Then name it and run the
installer again:

```bash
echo 'BACKUP_FILES_DESTINATION="/mnt/appliance-backup"' | sudo tee -a /etc/understandtech/local.env
sudo ut-install --skip-pull
docker compose up -d
```

The installer refuses a directory on this machine's own disk, the root one or
the one holding `DATA_ROOT`: that is a mount point with nothing mounted yet, and
a backup written there dies with the machine. Once it has checked, it writes
`.understandtech-backup-destination` into the directory.

**Before every run, the backup looks for that file.** When the share is not
mounted, it writes nothing, says so in its log, and its health check turns red.
An update that finds it unmounted says so too, and carries on:

```bash
docker compose logs files-backup | grep 'not mounted'
```

The first run creates the repository on the destination and copies everything;
later runs copy only what changed. The database archives stay on the machine as
well, where they always were.

To keep the backup on the machine again, empty `BACKUP_FILES_DESTINATION` and
run both commands once more.

#### To S3 or SFTP

```bash
BACKUP_FILES_REPOSITORY="s3:https://s3.eu-west-3.amazonaws.com/your-bucket/appliance"
BACKUP_FILES_S3_KEY_ID="AKIA..."
BACKUP_FILES_S3_SECRET="..."
```

Any S3-compatible endpoint works — AWS, MinIO, Scaleway, OVH. For SFTP, give
`BACKUP_FILES_REPOSITORY="sftp:backup@nas.example:/appliance"` instead. **Never
put a password in that address**: when the destination fails, the backup writes
the address in its log. Then run the installer again:

```bash
sudo ut-install --skip-pull
docker compose up -d
```

**This gives the backup service a way off the machine.** It is the one service
that reads every document, and Docker cannot narrow its network to the
destination: it can reach whatever the host can. The installer adds that network
only when the repository is S3 or SFTP, and takes it away when it is not. A disk
the host mounts, above, needs none. Name one destination only: given both, the
installer stops.

**SFTP needs two files**, in `/etc/understandtech/backup-ssh`, which the
service reads as root's `.ssh`. The installer makes the key, `id_ed25519`,
readable by root alone, and prints its public half: give it to the account on
the server. A key already there is kept, never replaced. The server's host key
is yours to pin:

```bash
ssh-keyscan nas.example | sudo tee /etc/understandtech/backup-ssh/known_hosts
```

**Check the fingerprint `ssh-keyscan` printed with whoever runs that server
before you keep it**: the backup trusts that key and no other, and refuses to
connect when the server's key changes. Until both files are there, every backup
is refused, and the installer says so. The public half stays in
`/etc/understandtech/backup-ssh/id_ed25519.pub`.

The first run creates the repository and uploads everything; later runs send
only what changed. Check it arrived:

```bash
docker exec ut-files-backup restic snapshots
```

When the destination does not answer, or when `BACKUP_FILES_PASSWORD` does not
open the repository there, the backup writes nothing and says which, by name, in
its log:

```bash
docker compose logs files-backup | grep -E 'cannot reach|does not open'
```

**Keep `BACKUP_FILES_PASSWORD` somewhere else than the machine.** It encrypts
the repository, so a remote copy is worth nothing without it — and a remote copy
is exactly what you reach for when the machine is gone.

### Load

```bash
WORKER_REPLICAS="2"
WORKER_CUSTOMER_REPLICAS="2"
```

Background document processing. More replicas, more parallel ingestion, more
memory.

### Gateway limits

```bash
GATEWAY_MAX_PROMPT_TOKENS="65536"
GATEWAY_RPM_PER_KEY=""
GATEWAY_RPM_PER_USER=""
GATEWAY_RPM_PER_KEY_TOTAL=""
```

A prompt estimated above `GATEWAY_MAX_PROMPT_TOKENS` is answered with a 400
instead of reaching the engine; `0` lifts the cap. Each API key may make
`GATEWAY_RPM_PER_KEY` requests a minute, 60 when empty. The App Builder's key
acts for many people, so each of them gets `GATEWAY_RPM_PER_USER` — the per-key
limit when empty — and all of them together `GATEWAY_RPM_PER_KEY_TOTAL`, ten
times the per-key limit when empty, `0` to lift it.

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

Four variables make a stack independent of anything else on the machine:

```bash
COMPOSE_PROJECT_NAME="staging"
RESOURCE_PREFIX="staging"
CONTAINER_PREFIX="staging"
DATA_ROOT="/var/lib/understandtech-staging"
```

`COMPOSE_PROJECT_NAME` is not redundant. Four services carry no fixed container
name — `workers`, `workers-customer`, `llm` and `nim-llm`, because a fixed name and `--scale` are mutually exclusive. Compose names those after the
project, so setting only the prefixes leaves them colliding with the other
stack.

Add `UT_HTTP_PORT` and `UT_HTTPS_PORT` if the first stack already holds 80 and
443.

## Opening inference to another machine

The inference engine checks no key. Another machine reaches it through a
compute node's Caddy, which serves it on port 8444 to the platforms paired with
the node by `ut-pair`, by their certificate, and to no other. `sudo ut-install
--compute 10.42.0.7` writes what that takes into `local.env`:

```bash
COMPOSE_FILE="compose.yaml:compose.compute.yaml"
UT_INFERENCE_ADDRESS="10.42.0.7"
UT_ADMITTED_BOXES_FILE="/etc/understandtech/admitted-boxes.caddy"
```

`UT_INFERENCE_ADDRESS` is the name or address the platform reaches the node by,
never a `.local` name. `UT_ADMITTED_BOXES_FILE` is the list `ut-pair` keeps of
the platforms the node serves; edit it with `ut-pair`, never by hand.
`UT_INFERENCE_BIND_ADDRESS` narrows the interfaces port 8444 listens on,
`UT_INFERENCE_PORT` moves it.

On the platform, `sudo ut-install --inference-from 10.42.0.7` points the
services at its own Caddy and names the file `ut-pair join` writes:

```bash
COMPOSE_FILE="compose.yaml:compose.remote-inference.yaml"
VLLM_LLM_BASE_URL="http://caddy:8445/v1"
UT_LINKED_NODE_FILE="/etc/understandtech/linked-node.caddy"
```

The engine publishes no port on the host: it checks no key, and reaches other
machines only through that surface. To query it on the machine itself:

```bash
docker compose exec nim-llm curl -s localhost:8000/v1/models
```

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
