# What a machine looks like before an install

An installer is never run on the machine it was written on. This is the list of
states a machine is really found in, what has to happen in each, and which check
holds it.

It exists because three defects reached a customer machine on the same
afternoon, all in the same twenty lines, and none of them was reachable by the
checks as they stood: every check verified a property in isolation, and nothing
walked the installer from a known starting point.

## What the machine must have

| | Why | Checked by |
|---|---|---|
| Docker 24 or newer | Compose v2 syntax and `--format json` | `ut-install --check`, blocking |
| Compose v2 | the stack is described in compose files | `--check`, blocking |
| A GPU reachable from containers | inference containers will not start otherwise | `--check`, blocking |
| 250 GB free | model weights and document storage | `--check`, blocking |
| 24 GB of RAM | below that, workers are starved | `--check`, warning |
| `openssl` | certificate inspection in `ut-certificate` | the package depends on it |
| A registry token | the images are private — anonymous pulls answer `403` | `ut-install` asks |
| `git` | **only** when the release is cloned rather than packaged | `--check`, conditional |

That last line was a defect: `git` was required unconditionally, so an install
from the package stopped on a tool it never uses.

## The states, and what has to happen

Each row is a starting state the machine can be in. `test/fresh-install.sh`
builds it in a container, runs the installer, and checks the outcome.

| Starting state | What has to happen |
|---|---|
| **Nothing but the package.** No `.env`, no volumes. | Installs. Every required variable gets a value, and the result renders a stack. |
| **The settings directory is gone.** Someone removed `/etc/understandtech`. | It is recreated. The link from the release directory is no longer dangling. |
| **The settings file exists and says nothing.** An empty `.env`. | Filled from the template, not kept. An empty file is not a configured machine. |
| **Already configured.** A complete `.env`, a running install. | Running the installer again changes nothing. |
| **A database nobody has the password for.** A mongo volume is there, `.env` holds no password. | **Stops**, names the volume, gives the two ways out. |
| **Two separate machines.** | They do not share a secret. |

### Why the last two matter more than they look

**The orphan volume** is not hypothetical — it is what a machine looks like
after `docker compose down`, a cleanup of images, and a removed checkout. The
volumes and `/var/lib/understandtech` stay. Generating a new password there
would not reach the database, because mongo reads it once, when it creates its
data directory. The stack would start and fail to connect, with nothing saying
why. Refusing is the only honest outcome.

**Two machines sharing a secret** is the defect `JWT_SECRET` already caused: a
value identical everywhere means a token minted on one is accepted on another.
Anything the installer generates has to differ between two runs, and that is
worth checking rather than assuming.

## How far the walk goes, and why not further

The installer is run to the point where it would pull images. That is the limit:
the images are private and weigh tens of gigabytes, so a CI runner cannot reach
a running stack.

It is not much of a limit. **Everything that has ever broken here broke before
that line** — writing the settings, generating the secrets, reading the state of
the machine. What follows is a download and a healthcheck.

Docker and `nvidia-smi` are answered by stubs. That is not only to keep the run
hermetic: a starting state like "a mongo volume is already there" is a sentence
only a stub can say without creating one on the machine running the test.

The settings the installer writes are then rendered against the real compose
files. So the walk proves what was written, and the render proves it is usable.

## Running it

```bash
./test/fresh-install.sh
```

About two minutes, and it needs Docker. It runs on every release, before
publishing: a release that cannot install on a bare machine must not be
published.

Each property is also broken on purpose in `test/discrimination.sh`, under
*A fresh install, seen failing*. A check nobody has watched fail is a check
nobody knows works — and two of these were pointed at the wrong thing until
their breaking direction was run.

## Not covered yet

**Migrating an installation that lives in a git checkout.** The two layouts
coexist, so nothing is broken meanwhile, but nothing moves either. The hard part
is not the files: it is that such a machine carries variables the release no
longer defines, and an explicit value wins over a derived one.

**A real start.** No check reaches `docker compose up`, so healthchecks, model
loading and the first sign-in are verified on a machine, by hand.
