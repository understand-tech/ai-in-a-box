# Repository checks

## What is here

| File | Purpose |
|---|---|
| `capabilities.sh` | Checks what the deployment can do, one line per capability. Needs Docker; renders configurations and exercises the backup, starts no application service. |
| `invariants.sh` | Checks the repository against eight invariants. No dependencies beyond bash and coreutils, runs in under a second. |
| `machine-identity.sh` | Validates the certificate mechanism intended to replace the shared JWT_SECRET. **Not a product capability yet** — nothing here runs a CA. Nightly. |
| `database-restore.sh` | Proves a backup archive restores, end to end. Nightly. |
| `known-issues.txt` | Problems that already exist and are accepted for now, with the reason next to each. |
| `allowed-ports.txt` | Ports intentionally published on every interface. |

## Where they run

| Workflow | Trigger | Runs | Takes |
|---|---|---|---|
| `checks.yml` | every push and pull request | `invariants.sh`, `capabilities.sh` | under a minute |
| `nightly.yml` | 3 a.m. and manual — **neither works yet**, see below | `machine-identity.sh`, `database-restore.sh` | about six minutes |

Run the first two from anywhere:

```bash
./test/capabilities.sh
./test/invariants.sh
```

`capabilities.sh` prints what the deployment is verified to do. The whole list,
as of the `2026-Q4` branch:

```
Deployment topologies
  ✔ the default role renders a valid stack
  ✔ the App Builder overlay renders on top of it
  ✔ the control-plane role leaves out the inference engines

Backward compatibility
  ✔ an untouched install keeps its container, volume, network and data names

Multi-machine roles
  ✔ a compute node serves inference
  ✔ a compute node runs no database
  ✔ overriding the prefixes isolates every resource
  ✔ a machine without a GPU requests no NVIDIA device

Backup
  ✔ files are backed up and restore identically
  ✔ a missing backup is visible, and recovers when one appears

10 verified
```

The list grows with the branch, not with the file: each block is guarded by the
overlay it needs, so a branch without `compose.compute.yaml` prints four
capabilities instead of ten rather than failing.

That list is the point. Each line is a capability the product is expected to
have, checked on every push — so the output doubles as the specification, and a
capability nobody checks is a capability that does not appear. Add a line when
you add a capability; name it after what it does, not after the mechanism.

## Running the nightly checks

The other two start containers, so they are not on the push path:

```bash
./test/database-restore.sh     # about a minute
./test/machine-identity.sh     # about five, it waits for a certificate to expire
```

They need nothing but a Docker daemon — no secret, no registry credentials, and
`machine-identity.sh` builds its network with `--internal`, so neither needs
outbound access once the images are local.

Every container, volume and network they create carries the shell's PID, and
both clean up after themselves on exit. Two runs can therefore overlap, and
either can run beside a live deployment without touching it.

**`gh workflow run nightly.yml` does not work, and that is not a local
problem.** GitHub only reads `schedule` and `workflow_dispatch` from the default
branch. `nightly.yml` lives on the release branches, not on `main`, so there is
no *Run workflow* button and the 3 a.m. cron was never armed either. `checks.yml`
is unaffected because `push` and `pull_request` are evaluated on the branch being
pushed.

Until that is resolved, run them by hand — on the target machine rather than a
generic runner, which is where they say the most: what they watch for is the
upstream `mongo`, `db-backup` and `step-ca` images moving on their own.

## What it is for

Every check exists because of a defect that was actually found in this
repository — not because it is good practice. Each one is listed below with the
defect it catches. A check that cannot name one does not belong here: it will
produce a false positive eventually, and the whole thing gets switched off.

| Check | Idea | Defect it addresses |
|---|---|---|
| `plaintext-secret` | A shipped secret is a shared secret | `JWT_SECRET` identical at every customer: a token minted at one is accepted at another |
| `compose-secret-default` | A secret ships from more than one file | `MONGODB_PASSWORD` fell back to `12345678` in `compose.yaml`, which emptying `.env.example` would not have touched |
| `undeclared-variable` | A variable with no default must be declared | Compose substitutes an empty string, so the stack starts misconfigured instead of refusing to start |
| `unlisted-port` | Reaching the network must be deliberate | Database and inference engines reachable from the LAN, inference without authentication |
| `unpinned-image` | A tag moves, a digest does not | Two boxes reporting the same version run different software, and a diagnosis on one no longer transfers |
| `verbose-log-level` | The shipped default is the installed default | `LOG_LEVEL=DEBUG` in production, with sensitive content in the logs |
| `queue-eviction` | A queue is not a cache | Redis on `allkeys-lru` drops tasks under memory pressure, with no error |
| `missing-documented-path` | A wrong document costs an installation | Preventive: a file renamed without updating the README |

How each one decides is the `check_*` function of the same name in
`invariants.sh`. They are short and read top to bottom.

## How the baseline works

The repository had none of these checks and plenty of the defects. Turning them
all on at once would have made every open pull request red for reasons none of
them caused — which is how a CI gets bypassed in a week.

So `invariants.sh` fails on two things:

- **a problem not in `known-issues.txt`** — something new was introduced;
- **a line in `known-issues.txt` whose problem no longer exists** — it was fixed,
  and the line has to go.

The second half is what keeps the file honest. A baseline nobody prunes is a
permanent suppression list, and the check stops protecting anything.

Both directions were verified when the script was written: removing a line makes
it fail with "New problems", adding a line for a non-existent problem makes it
fail with "Fixed problems still listed".

## Adding a check

1. Write a `check_*` function that calls `report <stable-id> <message>` for each
   problem it finds.
2. Call it from `main`.
3. Run the script. Everything it now reports appears as new.
4. For each report, either fix the problem or add its identifier to
   `known-issues.txt` **with the reason**.

The identifier has to be stable across unrelated edits, since it is the key the
baseline matches on. `plaintext-secret:JWT_SECRET` is stable; anything carrying a
line number is not.

The message is read by whoever gets the failure, months from now, on a change
that has nothing to do with the check. Say what is wrong and why it matters, not
which rule fired.

## Validations, which are not capabilities

`machine-identity.sh` sits apart from `capabilities.sh` on purpose. It checks
that a mechanism works — a local authority issuing client certificates against
single-use tokens, with the proxy requiring them — but **the product does not
use it yet**. Listing it among the capabilities would claim something the
appliance cannot do, which is the one thing that list must not do.

It is here because the decision to build on that mechanism rests on these
properties holding, and it runs in an `--internal` Docker network, so a pass
also means the mechanism needs no outbound access — the property an isolated
deployment depends on.

When the authority lands in the product, the lines move into `capabilities.sh`
and this file loses a section.

## Coming next

Not implemented yet. Listed so the gap is visible rather than assumed covered.

| Check | Idea | Defect it addresses |
|---|---|---|
| `caddy validate` × 3 | Three TLS modes, three paths to exercise | A broken ingress mode discovered by the customer who uses it |
| `caddy adapt` | Either the domain is configurable or it is not | A broken interpolation: the six hostnames no longer match the real address |
| `shellcheck` | Shell fails quietly | Unknown — it has never been run against these four scripts |
| unit tests | Pure functions test without a machine | `env_set` does not recognise a commented-out variable and appends a duplicate |
| stubbed installer | Idempotence is proven, not promised | A leaking token, a second run that is not a no-op, a missing terminal |
| undocumented variable | A default nobody can find is not a setting | `NIM_LLM_BIND_ADDRESS` decides whether a compute node is reachable and appears in no `.env.example`; having a default, `undeclared-variable` stays silent |
| Q3 → Q4 migration | Backward compatibility is proven on paper only | Unknown — `docker compose config` says the names are unchanged, no run has said the data survives |

`compose config` has since landed as the first three capabilities, which is
where a check belongs once it describes something the product does rather than
something it must not do.

## What this does not prove

The two checks on the push path read files. They do not start anything.

They say nothing about whether the images pull, the containers start, the
inference serves, or the platform works. A green run means no known class of
defect was reintroduced — nothing more. The nightly pair does start containers,
but a disposable MongoDB and a disposable authority are not this product.

Proving more takes a machine with a GPU, a registry it can pull from, and the
time for a cold start. None of that belongs in CI, so the first real install
stays the test that counts.
