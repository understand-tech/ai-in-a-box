# Updating

For the operator moving an appliance that is in service to a new version. After
reading you will know what to do before touching anything, what an update does
to the settings you have, and how to get back if it goes wrong.

An update is the operation that can cost a customer their data, so it is worth
doing in the order below rather than the order that seems quicker.

## 1 · Back up first, and check the backup

Not the scheduled one — a fresh one, now.

```bash
docker exec ut-mongodb-backup backup-now
docker exec ut-mongodb-backup sh -c 'ls -lt /backup/*.archive.gz | head -1'
docker exec ut-files-backup restic backup /data --tag pre-update
```

An archive you have not verified is not a backup. See
[restoring](restore.md#1--the-database) for the checksum check.

## 2 · Update

### Installed from the package

There is no package repository to upgrade from: a release is downloaded and
verified the same way it was installed, and `apt-get install ./file.deb`
upgrades an installed package as readily as it installs a new one.

```bash
VERSION=2026.09.2
BASE=https://github.com/understand-tech/ai-in-a-box/releases/download/v$VERSION

mkdir ut-update && cd ut-update
for f in understandtech_${VERSION}_all.deb understandtech_${VERSION}_all.deb.sig \
         ut-verify release.pub SHA256SUMS; do
    curl -fsSLO "$BASE/$f"
done
chmod +x ut-verify
./ut-verify understandtech_${VERSION}_all.deb

sudo apt-get install ./understandtech_${VERSION}_all.deb
sudo ut-install
```

**The verification is not a formality here either.** `dpkg` ships with
`no-debsig`, so it installs whatever it is given — see
[installing](install.md#2--check-it-before-you-install-it).

The upgrade replaces `/usr/share/understandtech` and **never touches
`/etc/understandtech`**, so your settings and generated secrets survive it —
they are not in the package, so there is nothing for it to overwrite. Data in
`/var/lib/understandtech` is untouched, and stays behind even if the package is
removed.

`ut-install` then generates whatever new variables the release made mandatory,
and restarts the stack. Caddy, the metrics recorder, the files backup and the App
Builder's proxy read a file from the release, so every new version recreates
them: a changed file reaches them without a reboot.

### Installed from a git checkout

```bash
cd /opt/understandtech
sudo ./bin/ut-install --update
```

`--update` is what fast-forwards the checkout. Without it the installer leaves
the working tree alone, on purpose: a support fix applied on the machine should
not disappear silently.

The installer then does what it always does — and that is the point. It **adds
what is missing** rather than failing on it.

It asks for the address again, and offers the one the machine already answers
on. Answering nothing keeps it. An unattended update — no terminal to ask on —
keeps it without asking. Passing `--domain` is what changes it, and changing it
is a move, not an update: see
[changing the address later](certificates-and-dns.md#changing-the-address-later).

## What an update does to your settings

`.env` is not a file you keep any more — it is built, every time the installer
runs, from two others:

| File | Whose it is | On an update |
|---|---|---|
| `/usr/share/understandtech/release.env` | ours | **replaced.** What this version decides: the exact images, defaults, model settings. No secret is ever in it |
| `/etc/understandtech/local.env` | yours | **never touched.** Your address, your overrides, and every secret the installer generated |
| `/etc/understandtech/.env` | built from the two | rebuilt. Yours wins over ours, every time |

That is what lets a new version change a default and have it reach your machine,
which an `.env` written once never allowed.

**Your first update splits the file you already have.** Anything in it that
matches what this version decides is dropped, because dropping it changes
nothing. The images (`*_IMAGE`) and the engine and model settings
(`NIM_LLM_PASSTHROUGH_ARGS`, `LLM_MAX_CONTEXT_LEN`, `GATEWAY_MODELS`,
`DOWNLOAD_ONNX_EMBED`) are left to this version too, whatever they said: the
values an older install wrote for them were its own release's, and kept, they
would win over the images this version was tested and signed with. Everything
else is kept as yours, and the installer says how many values differ from what
it would have chosen:

```
[ ok ] Split the settings: 41 kept as yours, 2 of them differing from this release
[ ok ] 15 left to this release, which decides them: LLM_IMAGE, API_IMAGE, …
[ ok ] The file as it was: /etc/understandtech/env.before-split
```

**Those two are not changed.** An update is the wrong moment to move a service,
so a setting that differs is reported, never resolved. Aligning one is a
separate, deliberate edit to `local.env`. An image or an engine setting of your
own is not carried over: its old value stays in `env.before-split`; set it again
in `local.env` if you need it.

New versions also make variables mandatory, and the stack refuses to start
rather than run misconfigured. The installer generates each one and prints it
once. **Write down the backup password** — without it no snapshot can be read,
including the certificate authority's root.

If you update by hand instead — `docker compose up -d` without running the
installer — the stack stops with `required variable BACKUP_FILES_PASSWORD is
missing`. That is the designed behaviour, not a bug: a backup that is silently
unencrypted is worse than a stack that will not start.


## 3 · Verify

```bash
docker compose ps
```

Every service `healthy`. Then check one document you know, in the platform.

## What changes that you will notice

**`nim-vlm` is gone.** The chat model, `Qwen3.8-27B` on `nim-llm`, now reads
images too. The release points `VLLM_VLM_MODEL`, `VLLM_VLM_BASE_URL`,
`GATEWAY_VLM_MODEL` and the `uai-vision` entry of `GATEWAY_MODELS` at it. If the
installer reports one of them as differing in `local.env`, remove that line from
`local.env`: it wins over the release and names a container that no longer
exists.

Its weights stay in the `ut-nim-vlm-cache` volume. Once an image has been read
in the platform, `docker volume rm ut-nim-vlm-cache` frees the disk.

**The chat model takes the memory vision gave back.** `NIM_LLM_PASSTHROUGH_ARGS`
now starts `nim-llm` with `--gpu-memory-utilization 0.75` instead of 0.55. On a
GB10 its context cache grows from about 210 000 to 720 000 tokens, which is what
keeps returning conversations from being read again. If the installer reports
that line as differing in `local.env`, the old value stays in force until you
remove it there.

**`ut-install` now removes the containers the release no longer declares**, as
the boot service always did at every restart. That is what takes the old
`nim-vlm` down before `nim-llm` asks for its memory. A service you started from
a compose file of your own is removed too, unless that file is listed in
`COMPOSE_FILE` in `local.env`.

**Three containers lost their fixed names.** `ut-llm`, `nim-llm` and `nim-vlm`
are now named after the Compose project — `understandtech-llm-1` and so on. A
fixed name and `--scale` are mutually exclusive, and scaling those three is the
point of a compute node.

`nim-llm` and `nim-vlm` keep working as *hostnames*: their container name
matched their service name, which stays a network alias. Only `ut-llm`
disappears for good. Any script of yours that runs `docker logs ut-llm` needs
updating; nothing inside the appliance referred to it.

Compose recognises the old container by its labels and recreates it, so nothing
is orphaned and **volumes follow** — the model weights are not downloaded again.

**Published ports moved to loopback.** MongoDB on 27018 and the inference
engines on 8001/8002 now listen on `127.0.0.1` only. If something outside the
machine relied on reaching them, it stops working — deliberately, since the
engines check no key themselves. A compute node serves other machines through
Caddy, which does.

**`step-ca` is gone, and with it the surface on port 8443.** Each box keeps one
certificate authority, Caddy's, which already signed what browsers see. The
update removes the `ut-step-ca` container and its network; its root stays in
`/var/lib/understandtech/ca`, which nothing reads any more. Once the update is
verified, `sudo rm -rf /var/lib/understandtech/ca` frees it. A load balancer
that verified the box through port 8443 has to trust the box's Caddy root
instead.

**An administration console answers on port 8443.** The first update that
carries it creates the `ut-console` account and the two units it runs on, and
shows the console password once, after the other two — only on a terminal: an
update with none says to run `sudo ut-install --reset-console-password`. Later
updates keep the password. The port is the one `step-ca` held; a load balancer
that still knocks on it now reaches the console. See
[the administration console](console.md).

**Two volumes are no longer used.** `ut-llm-ollama` and `ut-vllm-llm-cache` stay
on disk, empty or unused: `docker volume rm ut-llm-ollama ut-vllm-llm-cache`
frees them.

**The TLS settings are given to the installer.** `ut-install --certificate-dir`
and `--behind-proxy` replace editing `UT_INGRESS_MODE`, `UT_CADDY_SCHEME` and
`UT_TRUSTED_PROXIES` by hand; settings already in `local.env` keep working.
`UT_PUBLIC_SCHEME` is gone: the addresses the applications advertise are always
`https`. A `local.env` that set it to `http` sees them move to `https`.

**A platform and its compute node are paired again.** The node no longer
answers the bearer of its `VLLM_API_KEY`: it serves the platforms paired with it
by `ut-pair`, and no other. Update both machines, then pair them: `sudo ut-pair
offer` on the node, `sudo ut-pair join <node>` on the platform — the platform's
update prints that command with the node's address. Until then the platform
answers nothing a model has to write. The key and root files the platform was
given, and its `inference-ca-bundle.pem`, are no longer read; the update removes
the bundle. See
[pairing a platform with it](certificates-and-dns.md#pairing-a-platform-with-it).

**The model weights are downloaded by `ut-install`.** It fetches the files the
release pins, checks each checksum, and places them where the engines read them;
nothing is fetched by a container any more. The first update of a box that
fetched its weights itself downloads them once more, some 27 GB for the model
the release ships. `ut-llm` no longer downloads the ONNX embedding model, which
the release does not use.

**The browser warning may change.** If you switch the public certificate over to
the local authority, every already-paired browser sees a new fingerprint and
warns again. That switch is a deliberate act, never part of an update.

**The engine no longer declares a host port.** `127.0.0.1:8001` was declared but
never answered: Docker publishes no port for a container that sits on internal
networks only, as the engine does. Query it with `docker compose exec nim-llm
curl -s localhost:8000/v1/models`, or from a platform paired with a compute
node. A `NIM_LLM_BIND_ADDRESS` or `NIM_LLM_HOST_PORT` left in
`local.env` is now ignored.

**Neither does MongoDB.** `127.0.0.1:27018` never answered either, for the same
reason. Reach the database with `docker compose exec mongodb mongosh`; a
`MONGODB_HOST_PORT` left in `local.env` is ignored.

## If the update goes wrong

Nothing is rolled back and nothing is lost: re-running the same command resumes.

To go back to the previous version, install the package you came from and run
the installer again:

```bash
sudo apt-get install ./understandtech_<previous>_all.deb
sudo ut-install
```

A previous version without the administration console leaves its two units
behind, restarting on programs that are gone:
`sudo systemctl disable --now ut-console ut-agent` stops them.

`.env` stays one flat, complete file at the same path, so a version that knows
nothing of `local.env` reads it anyway. Two checks in `test/migration.sh` hold
that: the settings left behind stand on their own, and the previous version's
compose files render a stack from them.

On an install that still lives in a git checkout, `git checkout <previous-commit>`
followed by `docker compose up -d` does the same thing.

The data is untouched either way — volumes and `DATA_ROOT` are not versioned. If
the data itself is wrong, see [restoring](restore.md).

## Rehearsing an update

`test/migration.sh` answers what an update does to an existing install, from
the environment file the previous version shipped: which variables become
mandatory, which names disappear, whether every service that talks to the
database can still reach it.

`test/migration-on-data.sh` runs the update on a real database and document
tree, beside whatever else the machine runs, and compares the shape, the
contents and the files. Point `MIGRATION_ARCHIVE` at a production archive to
rehearse with the customer's own data:

```bash
MIGRATION_ARCHIVE=/path/to/mongo.archive.gz ./test/migration-on-data.sh
```

It installs under its own project and prefixes, and refuses to start if any
rendered name falls outside its own namespace.

## What this document does not cover

**What is new in a version.** This page is the procedure, not the release
notes. What changed is on the release itself.

**Changing a setting outside an update.** That is
[configuration](configuration.md); this page only says what an update does to
the settings already there.

**Restoring after a failed update.** Going back to the previous version is
covered above; putting data back is [restoring](restore.md).

**Updating a second machine enrolled against this one.** Nothing here covers a
fleet; see the machine-facing surface in
[certificates and DNS](certificates-and-dns.md).
