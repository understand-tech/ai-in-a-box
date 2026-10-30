# The administration console

For the administrator of a box who has no terminal on it. After reading you
will know where the console is, how to sign in, what it shows, what it keeps of
what you did, and what to do when it does not answer.

This version only reads. Nothing on its pages changes the box: updating,
backing up, restoring and changing a setting still happen in a terminal, as
[updating](update.md) and [restoring](restore.md) say.

## Opening it

```text
https://<UT_DOMAIN>:8443
```

Account `admin`, with the console password. It answers on port 8443, on every
interface, under the box's address and no other: opened by its IP or by another
name, it answers `not this address`. Open the port in any firewall between your
desk and the box.

The console is not behind Caddy. It runs on the machine itself, beside the
stack, so a stopped Caddy or a stopped stack does not take it down.

## The password

`ut-install` draws it the first time it installs the console — on a fresh
install or on the first update that carries it — and shows it **once**, on the
terminal, after the two other passwords:

```text
  Console password  4f0c9a…
  Account admin, at https://box.example.com:8443. Shown here only — this box keeps its hash, never the password.
```

The box keeps only a PBKDF2-SHA256 hash of it, in
`/var/lib/understandtech/console/password`. An update keeps it.

An install with no terminal — through the page `ut-setup` opens, or unattended —
has nowhere to show a password, so it draws none and says so. The console then
answers that it has no password yet. To give it one, or to replace a lost one,
in a terminal on the box:

```bash
sudo ut-install --reset-console-password
```

It shows a new password once, keeps its hash, and closes every open session.
Nothing else changes.

## Signing in

A session ends after 15 minutes without a request, and after 8 hours in any
case. **Five wrong passwords in a row block signing in for 15 minutes**, for
everyone: there is one account. The block, and every sign-in, refused or not,
is kept in the activity.

The console refuses to let anyone in when it cannot write the activity: a
sign-in nobody can trace does not happen.

## What it shows

- **Overview** — the release installed, the address, the model, each service
  with its state and health, the last file backup, the free space on the root
  disk and on the data disk, the end of the license, and whether usage reports
  go out. **Ask again** reads the box again.
- **Logs** — the last 100, 200 or 500 lines of one service, as
  `docker compose logs` prints them. Only the services this box runs can be
  chosen. A service writes what it writes: read its logs knowing that.
- **Activity** — the last 200 lines of the activity, newest first.

## The activity

Every sign-in, sign-out, refused request and log read is one line: when, who,
what, and how it ended. A password is never in it, nor any value a request
carried.

It is kept in `activity/activity.jsonl` under `DATA_ROOT` —
`/var/lib/understandtech/activity/activity.jsonl` by default — readable by root
alone, and only ever added to. The console cannot change it. It lives under
`DATA_ROOT`, so the files backup takes it with everything else.

## How it is built

Two systemd units, which `ut-install` installs with the boot service:

| Unit | Runs as | What it does |
|---|---|---|
| `ut-agent.service` | root | Answers the console's questions on `/run/ut-agent/agent.sock`, which only root and the `ut-console` group can open. It runs fixed commands only — `docker compose ps`, `docker compose logs` for a service the box runs, `ut-send status`, `ut-license field expires` — and refuses everything else, noting the refusal in the activity |
| `ut-console.service` | `ut-console` | The pages, on port 8443. The account has no shell and is in no group but its own, Docker's least of all; the unit takes away every capability and makes the system read-only to it |

The console asks the agent for everything it shows, and has no other way to
reach the box. `ut-install --no-autostart` installs neither unit.

## Its certificate

The agent writes it, in `/var/lib/understandtech/console/tls.pem`, readable by
root and the console. Where it comes from follows `UT_INGRESS_MODE`:

- **`internal`** — signed by the root of Caddy's own authority, the one the
  browsers of your users already trust if you installed it, as
  [certificates and DNS](certificates-and-dns.md) says. It lasts 30 days and is
  renewed 10 days before it ends, whether Caddy runs or not, as long as Docker
  answers.
- **`custom`** — the certificate and key you gave the installer, the ones Caddy
  serves. A new one reaches the console within the hour.
- **`edge`** — none. Your load balancer holds the certificate and Caddy keeps no
  authority of its own, so the console has nothing to serve and does not answer.
  This version has no way around it.

## When it does not answer

```bash
systemctl status ut-agent ut-console
journalctl -u ut-agent -u ut-console -n 50
```

| What you see | What it means |
|---|---|
| The browser cannot connect | `ut-console` is not running, or a firewall closes 8443 |
| The connection is reset during TLS | No certificate yet: the agent's journal says why |
| `not this address` | The console was opened under another name than `UT_DOMAIN` |
| `This console has no password yet` | Run `sudo ut-install --reset-console-password` |
| `The agent does not answer` | `ut-agent` is not running |
| `No service could be listed` | Docker does not answer the agent |
