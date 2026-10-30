# Backing up

For whoever answers for an appliance's backups, and for whoever audits them.
After reading you will know what is backed up and what is not, how much data a
loss can cost, what the backup destination has to provide, which two secrets
must be kept away from the machine, and what to check, how often, and where to
write it down.

How to configure each setting is in [configuration](configuration.md#backups);
how to get the data back is in [restoring](restore.md).

## What is backed up

| What | How | Where it lives on the machine |
|---|---|---|
| Every database | a full-server `mongodump`, gzip, by `mongodb-backup` | the `ut-mongodb-backup` volume |
| Documents and App Builder projects | `restic`, encrypted, by `files-backup` | `DATA_ROOT`, `/var/lib/understandtech` by default |
| The database dumps above | the same `restic` run | the `ut-mongodb-backup` volume |
| The authority browsers trust | the same `restic` run | the `ut-caddy-data` volume |

The database leaves the machine inside the `restic` repository, never on its
own.

## What is not, and why

| What | Why |
|---|---|
| The databases of App Builder applications (`workspaces/*/mongo-data`) | Database files copied while they are written restore into a corrupt state. Each needs a dump of its own, which is not built. |
| `/etc/understandtech/local.env` | It lives outside `DATA_ROOT`. It goes into [escrow](#the-two-secrets-kept-away-from-the-machine) instead. |
| The link authority between a compute node and its platform | On purpose: whoever held a backup could otherwise pass for the box. A restored box is paired again. |
| The models | They come with the release, or are downloaded again. |
| Redis | It holds the queue of background jobs and short-lived state: sign-in challenges, login attempt counters, session revocations, caches. A restore loses the jobs that were running, which are submitted again; on another machine, new secrets end every session anyway. |

## Schedule, and how much a loss can cost

The two services run on two clocks:

- the database dump starts with the service, then repeats every
  `BACKUP_INTERVAL` minutes — 24 hours by default;
- the `restic` run is at `BACKUP_FILES_AT`, 03:00 by default, and carries the
  latest dump it finds.

With the defaults, the dump `restic` carries can be up to a day old, so the
database copy that leaves the machine can lag its files by as much. **On an
appliance in service, set the dump half an hour before the `restic` run**, in
`/etc/understandtech/local.env`:

```bash
BACKUP_BEGIN="0230"
```

then apply it, as every change to that file:

```bash
sudo ut-install --skip-pull
docker compose up -d
```

Until 02:30 comes, a freshly started machine carries no dump, and the health of
`mongodb-backup` reads `unhealthy`; that is why the release does not ship this
value.

**With that setting, the recovery point objective is 24 hours**, and 24 hours 30
minutes for the copy that left the machine: a loss costs at most what was
written since the last 02:30 dump and 03:00 run.

Two limits remain, and an audit should see them written:

- **The dump is not a single point in time.** A standalone MongoDB is read one
  collection after the other while it keeps writing. At 02:30, with nobody
  using the platform, little changes during the dump; with activity at night,
  a restore can bring back two collections that disagree.
- **The database and the files are taken half an hour apart.** A document
  uploaded between 02:30 and 03:00 is in the files without its record in the
  database: it is an orphan, never a record pointing to a missing file.

## How long the dump stays readable on the machine

The dump is compressed, **not encrypted**, and kept in its volume for
`BACKUP_CLEANUP_TIME` minutes — 30 days by default. A document a user deleted
stays readable there for as long.

The encrypted history lives in the `restic` repository, so the plain dumps add
nothing past the last two. Keep two days:

```bash
BACKUP_CLEANUP_TIME="2880"
```

Older dumps are restored from `restic`, as in
[restoring on another machine](restore.md#on-another-machine).

## What the destination has to provide

The reference is the 3-2-1-1-0 rule: three copies, on two kinds of media, one
off the site, one that cannot be altered, and zero errors at the last restore
checked. The appliance provides part of it; the destination provides the rest.

| | Provided by the appliance | Required of the destination |
|---|---|---|
| **3 copies** | the live data | the `restic` repository, and the copy its owner keeps of it |
| **2 media** | the machine's own disk | another one: a NAS, an S3 bucket, an SFTP server |
| **1 off the site** | — | that copy, outside the building the machine is in |
| **1 immutable** | — | snapshots of the destination taken by its owner, that the appliance cannot delete |
| **0 errors** | `restic check` after every run | a restore exercise, as in [restoring](restore.md) |

**A destination off the machine is mandatory.** The default keeps the
repository in the same volume as the dumps, which protects against nothing that
destroys the machine; [configure one](configuration.md#sending-backups-off-the-machine)
before the appliance holds data that matters.

**The immutable copy is the destination's job.** The machine holds the
credentials of its destination: an attacker who controls the machine can delete
the repository there, and a ransomware that encrypts the files sends encrypted
files at the next run. Snapshots taken on the NAS, or on the server, by its
owner protect against both.

A destination that refuses deletion itself — a `rest-server` in
`--append-only` mode, or an S3 bucket with object lock — also refuses the
retention the appliance applies after each run: the run writes its snapshot,
then fails at `restic forget`. Retention then belongs to the destination's
owner.

## The two secrets kept away from the machine

| Secret | Why it matters |
|---|---|
| `BACKUP_FILES_PASSWORD`, in `/etc/understandtech/.env` | Without it, no snapshot can be read — not the ones off the machine, not the authority's root. There is no recovery path. `ut-install` prints it once at the end of the install. |
| `/etc/understandtech/local.env` | The TLS mode and the customer's certificate, the backup destination and its credentials, and every value changed from the release. It is in no backup. |

For each appliance, write down before it holds data:

- where each of the two is kept — a vault of the customer's, a sealed envelope,
  a password manager — never on the machine alone;
- who holds it, and who can get it back when that person is away;
- the date it was last checked.

**Check the escrow, not only its existence**: once a year, and after any change
of person, open the repository with the escrowed password, from another
machine, with the destination's credentials as in
[restoring](restore.md#2--the-customers-files):

```bash
read -rs RESTIC_PASSWORD && export RESTIC_PASSWORD
docker run --rm -e RESTIC_PASSWORD -e RESTIC_REPOSITORY='<the destination>' \
    restic/restic:0.18.1 snapshots --latest 1
```

A snapshot listed proves the escrowed password opens the repository.

## Who checks what, and how often

For each appliance, name a person for each line:

| When | What | How |
|---|---|---|
| At install | the destination is configured, the first snapshot is there | `docker exec ut-files-backup restic snapshots` |
| At install | both secrets are in escrow | the [escrow check](#the-two-secrets-kept-away-from-the-machine) |
| Every day | both backup services are healthy | `docker compose ps mongodb-backup files-backup` |
| Every week | every run of the week ended with `done`, none with `nothing written` | the log of `files-backup`, below |
| Every quarter | a restore, end to end | [restoring](restore.md), on a machine other than the one in service |
| Every year | the escrowed password opens the repository | the [escrow check](#the-two-secrets-kept-away-from-the-machine) |

The commands run from `/usr/share/understandtech`. The week's runs:

```bash
docker compose logs --since 168h files-backup | grep -E '\[files-backup\] (done|.*nothing written)'
```

**Keep a log of every check**: the date, the person, the snapshot it looked at,
the result, and what was done when it failed. An audit reads that log, not this
page.

## What this does not cover

**A pair of machines in high availability.** Which node backs up what, when
both serve, is not described yet.

**A database dump consistent to the second.** That takes a replica set and
`mongodump --oplog`; the appliance runs a single MongoDB.
