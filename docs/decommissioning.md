# Decommissioning

For the operator taking an appliance out of service — a customer leaving, a
machine being repurposed, a lab box being cleared. After reading you will know
what to keep before you destroy anything, what removing the package does **not**
remove, and what it takes to leave no customer data behind.

> **Removing the package removes almost nothing.** `prerm` deliberately leaves
> `/etc/understandtech` and `/var/lib/understandtech`, and there is no `postrm`
> — so even `apt purge` leaves both. Docker volumes are never touched by the
> package at all. A machine you believe you have wiped still holds the
> databases, the documents and the certificate authority's root.

## 1 · Decide what has to survive

Answer this before running anything, because the rest destroys it.

| Question | If yes |
|---|---|
| Does anyone need the data again? | Take a final backup, step 2, and check you can read it **elsewhere** |
| Is the machine being handed to someone else? | Everything in step 4 is mandatory, not optional |
| Is there an offsite copy? | It is not on this machine. Step 5 |
| Will another appliance reuse this address? | Publish the DNS change before the machine stops answering |

## 2 · Take a final backup, and verify it somewhere else

```bash
cd /usr/share/understandtech
docker exec ut-mongodb-backup sh -c 'ls -lt /backup/*.archive.gz' | head
docker exec ut-files-backup restic snapshots
```

A backup you have not restored is not a backup. Restore it on another machine
before you destroy the original — [restoring](restore.md) has the procedure for
a machine that no longer exists, which is what this one is about to become.

**Keep `BACKUP_FILES_PASSWORD`.** It is in `/etc/understandtech/.env`, and
without it every snapshot is unreadable for good. Copy it out now, while the
file still exists.

## 3 · Stop it, and stop it coming back

```bash
cd /usr/share/understandtech
sudo ./setup-autostart.sh --uninstall
docker compose down
```

`--uninstall` removes the boot service and the mDNS publisher. Without it the
machine republishes its names at the next reboot and answers for an appliance
that is no longer meant to exist.

`down` stops and removes the containers and the networks. **It does not remove
the volumes** — that is step 4.

## 4 · Remove the data

Nothing below is reversible. Step 2 is what makes it safe.

```bash
sudo apt-get purge understandtech

sudo rm -rf /etc/understandtech            # settings and every secret
sudo rm -rf /var/lib/understandtech        # documents, generated apps, the CA root

docker volume rm ut-mongodb-data ut-mongodb-backup ut-uploads-data \
                 ut-redis-data ut-caddy-data ut-caddy-config
docker volume rm ut-llm-ollama ut-llm-models ut-vllm-models \
                 ut-vllm-llm-cache ut-nim-llm-cache ut-nim-vlm-cache
```

The first `docker volume rm` line is the customer's: databases, backup
archives, uploads, queue state, and the proxy's certificates. The second is
model weights and caches — no customer data, but tens of gigabytes, so remove
them if the machine is being repurposed and keep them if it is being
reinstalled.

**The registry credential is separate and easy to forget:**

```bash
sudo docker logout ghcr.io
```

`ut-install` stores it under `root`, so logging out as your own user leaves it
in place.

If the App Builder was enabled, its generated applications ran as their own
compose projects with their own volumes, which none of the above touches:

```bash
docker volume ls
docker network rm proxy
```

## 5 · The copies that are not on this machine

Destroying the appliance destroys nothing held elsewhere. Deal with each
deliberately:

- **The offsite `restic` repository**, if `BACKUP_FILES_S3_KEY_ID` was set. It
  holds the databases, the documents and the authority's root, encrypted. Delete
  the bucket contents, or keep them and keep the password with them — an
  unreadable backup you cannot delete is worse than no backup.
- **The registry token.** Have it revoked; it is per-deployment.
- **The DNS records.** Six names, plus `*.apps.` if the App Builder was on.
- **The identity provider's application registration**, and the redirect URI
  pointing at this appliance.
- **A publicly trusted certificate**, if one was issued for this domain.

## 6 · Confirm

```bash
docker ps -a | grep ut-          # nothing
docker volume ls | grep ut-      # nothing
ls /etc/understandtech /var/lib/understandtech   # both gone
systemctl status understandtech ut-mdns-alias    # both gone
```

## What this document does not cover

**Revoking the machine from the certificate authority.** There is no
`ut-revoke`, and the appliance's certificates last seven days and renew on
their own. A second machine enrolled against this authority therefore keeps a
valid certificate until it expires, and destroying the authority is what stops
renewal. If a compute node was enrolled, take it out of service too. See
[certificates and DNS](certificates-and-dns.md#adding-a-second-machine).

**Secure erasure.** `rm -rf` and `docker volume rm` unlink; they do not
overwrite. A disk leaving your control needs whatever your organisation
requires for that — full-disk encryption already in place, a vendor erase, or
physical destruction.

**Anything a customer is contractually owed.** What data has to be handed back,
in what format, and by when, is not a technical question and nothing here
answers it.

**Moving an appliance rather than ending it.** Changing the address is in
[certificates and DNS](certificates-and-dns.md#changing-the-address-later);
moving the data to new hardware is a restore onto a fresh install, in
[restoring](restore.md).
