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

```bash
sudo apt-get install --only-upgrade understandtech
sudo ut-install
```

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

## What an update adds to an existing `.env`

New versions make variables mandatory. An `.env` written before them does not
have them, and the stack refuses to start rather than running misconfigured.
The installer generates each one:

| Variable | Introduced with |
|---|---|
| `BACKUP_FILES_PASSWORD` | the file backup |
| `CA_PASSWORD` | the certificate authority |

Both are printed once at the end. **Write down the backup password** — without
it no snapshot can be read, including the certificate authority's root.

If you update by hand instead — `git pull && docker compose up -d` — the stack
stops with `required variable BACKUP_FILES_PASSWORD is missing`. That is the
designed behaviour, not a bug: a backup that is silently unencrypted is worse
than a stack that will not start. Run the installer, or set the variables
yourself.

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

To go back to the previous version:

```bash
cd /opt/understandtech
git log --oneline -5
git checkout <previous-commit>
docker compose up -d
```

The data is untouched by this — volumes and `DATA_ROOT` are not versioned. If
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
