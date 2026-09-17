# Updating

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
and restarts the stack.

### Installed from a git checkout

```bash
cd /opt/understandtech
sudo ./ut-install --update
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
| `/usr/share/understandtech/release.env` | ours | **replaced.** What this version decides: image tags, defaults, model settings. No secret is ever in it |
| `/etc/understandtech/local.env` | yours | **never touched.** Your address, your overrides, and every secret the installer generated |
| `/etc/understandtech/.env` | built from the two | rebuilt. Yours wins over ours, every time |

That is what lets a new version change a default and have it reach your machine,
which an `.env` written once never allowed.

**Your first update splits the file you already have.** Anything in it that
matches what this version decides is dropped, because dropping it changes
nothing. Everything else is kept as yours, and the installer says how many
values differ from what it would have chosen:

```
[ ok ] Split the settings: 34 kept as yours, 4 of them differing from this release
[ ok ] The file as it was: /etc/understandtech/env.before-split
```

**Those four are not changed.** An update is the wrong moment to move a service,
so a setting that differs is reported, never resolved. Aligning one is a
separate, deliberate edit to `local.env`.

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
inference engines have no authentication. Set `NIM_LLM_BIND_ADDRESS` to open
one on purpose.

**The browser warning may change.** If you switch the public certificate over to
the local authority, every already-paired browser sees a new fingerprint and
warns again. That switch is a deliberate act, never part of an update.

## If the update goes wrong

Nothing is rolled back and nothing is lost: re-running the same command resumes.

To go back to the previous version, install the package you came from and run
the installer again:

```bash
sudo apt-get install ./understandtech_<previous>_all.deb
sudo ut-install
```

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
