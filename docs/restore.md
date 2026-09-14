# Restoring

Three things can be restored independently: the database, the customer's files,
and the certificate authority. Each has its own archive and its own command.

Every procedure below has been run end to end. Where a step says what to expect,
that is what it actually printed.

## Before anything else

**Do not restore over a running stack.** A restore into a database being written
to leaves a mixture of both states, and no error says so.

```bash
cd /opt/understandtech
docker compose stop api api-customer workers workers-customer llm
```

Leave `mongodb` running — the restore talks to it.

Write down what you are restoring *from*. `restic` and `mongodump` both keep
several snapshots, and picking yesterday's when you meant last week's is the
mistake that costs a second outage.

## 1 · The database

Archives are written daily by `ut-mongodb-backup` into the `ut-mongodb-backup`
volume, mounted at `/backup`.

**List what you have.**

```bash
docker exec ut-mongodb-backup sh -c 'ls -lt /backup/*.archive.gz' | head
```

**Check the archive is intact** — the backup container writes a checksum beside
each one.

```bash
ARCHIVE=$(docker exec ut-mongodb-backup sh -c 'ls -t /backup/*.archive.gz | head -1')
docker exec ut-mongodb-backup sh -c "cd /backup && md5sum -c '$(basename "$ARCHIVE").md5'"
```

Expect `OK`. A mismatch means that archive is unusable — take the previous one.

**Restore it.**

```bash
docker exec ut-mongodb-backup sh -c "cat '$ARCHIVE'" > /tmp/restore.gz
docker cp /tmp/restore.gz ut-mongodb:/tmp/restore.gz
rm -f /tmp/restore.gz

docker exec ut-mongodb mongorestore --gzip --archive=/tmp/restore.gz \
    -u "$USER" -p "$PASSWORD" --authenticationDatabase admin --drop
```

`$USER` and `$PASSWORD` are `MONGODB_USERNAME` and `MONGODB_PASSWORD` from
`/opt/understandtech/.env`.

`--drop` replaces each collection as it is restored. Without it, restoring onto
a database that still holds documents merges the two.

**To restore one database only**, rather than all of them:

```bash
docker exec ut-mongodb mongorestore --gzip --archive=/tmp/restore.gz \
    --nsInclude='ut-app-llms.*' -u "$USER" -p "$PASSWORD" \
    --authenticationDatabase admin --drop
```

**Verify.** Compare what came back with what the archive held:

```bash
docker exec ut-mongodb mongosh --quiet -u "$USER" -p "$PASSWORD" \
    --authenticationDatabase admin --eval '
    db.adminCommand("listDatabases").databases
      .filter(d => !["admin","local","config"].includes(d.name))
      .map(d => d.name + ":" + db.getSiblingDB(d.name).getCollectionNames().length)
      .sort().join(" ")'
```

A healthy appliance prints five databases. `test/database-restore.sh` performs
this whole cycle against a throwaway database, and compares document counts per
collection — run it if you want the mechanism checked before trusting it with
real data.

## 2 · The customer's files

Documents live under `DATA_ROOT` (`/var/lib/understandtech` by default) and are
backed up by `restic` into the same volume, at `/backup/restic`.

**List the snapshots.**

```bash
docker exec ut-files-backup restic snapshots
```

**Restore the latest one**, into a staging directory rather than over the live
one:

```bash
docker exec ut-files-backup restic restore latest --target /tmp/restored
docker exec ut-files-backup ls /tmp/restored/data
```

Compare, then move what you need into place. Restoring straight over `/data`
would be quicker and gives you nothing to compare against if it goes wrong.

**To restore a single path:**

```bash
docker exec ut-files-backup restic restore latest \
    --target /tmp/restored --include /data/app-data
```

**If the whole machine is gone**, point `restic` at the repository from
anywhere:

```bash
docker run --rm -v /path/to/repository:/backup -v /somewhere:/out \
    -e RESTIC_REPOSITORY=/backup/restic -e RESTIC_PASSWORD='...' \
    restic/restic:0.18.1 restore latest --target /out
```

`RESTIC_PASSWORD` is `BACKUP_FILES_PASSWORD` from `.env`. **Without it the
snapshots cannot be read at all** — no support path, no recovery. It is printed
once at install time and stored nowhere else.

## 3 · The certificate authority

The authority's root lives at `${DATA_ROOT}/ca`, so the file backup above
carries it. Restoring the files restores the authority.

**After a restore, check the root is the one you had:**

```bash
docker exec ut-step-ca step certificate inspect /home/step/certs/root_ca.crt --short
```

If the fingerprint matches what the appliance used before, every certificate it
ever issued is still valid and every machine renews as usual. If it does not,
the authority is a new one and anything enrolled against the old one has to be
enrolled again.

`test/machine-identity.sh` proves this cycle: back up the root, erase it,
restart the authority on the restore, and renew a certificate issued before the
failure.

## 4 · Start again

```bash
cd /opt/understandtech
docker compose up -d
docker compose ps
```

Wait for every service to read `healthy`. Then open the platform and check one
document you know the content of — a service that starts is not a service that
kept its data.

## What this does not cover

**The databases of generated applications.** The App Builder starts one MongoDB
per application under `workspaces/*/mongo-data`, and the file backup excludes
them on purpose: database files copied while they are written restore into a
corrupt state. They need a dump each, which is pending a product decision.

**Anything outside this machine.** The `restic` repository defaults to
`/backup/restic` — the same volume as the database archives. Losing that volume
loses both. Set `BACKUP_FILES_REPOSITORY` to an S3 or SFTP destination if the
data matters more than the machine does.
