# Repository checks

## What is here

| File | Purpose |
|---|---|
| `invariants.sh` | Checks the repository against a set of invariants. No dependencies beyond bash and coreutils, runs in under a second. |
| `known-issues.txt` | Problems that already exist and are accepted for now, with the reason next to each. |
| `allowed-ports.txt` | Ports intentionally published on every interface. |

Run it from anywhere:

```bash
./test/invariants.sh
```

## What it is for

Every check exists because of a defect that was actually found in this
repository — not because it is good practice. Each one is listed below with the
defect it catches. A check that cannot name one does not belong here: it will
produce a false positive eventually, and the whole thing gets switched off.

| Check | Idea | Defect it addresses |
|---|---|---|
| `plaintext-secret` | A shipped secret is a shared secret | `JWT_SECRET` identical at every customer: a token minted at one is accepted at another |
| `undeclared-variable` | A variable with no default must be declared | Compose substitutes an empty string, so the stack starts misconfigured instead of refusing to start |
| `unlisted-port` | Reaching the network must be deliberate | Database and inference engines reachable from the LAN, inference without authentication |
| `unpinned-image` | A tag moves, a digest does not | Two boxes reporting the same version run different software, and a diagnosis on one no longer transfers |
| `verbose-log-level` | The shipped default is the installed default | `LOG_LEVEL=DEBUG` in production, with sensitive content in the logs |
| `queue-eviction` | A queue is not a cache | Redis on `allkeys-lru` drops tasks under memory pressure, with no error |
| `missing-documented-path` | A wrong document costs an installation | Preventive: a file renamed without updating the README |

Longer version of each, with the exact mechanism and its limits, in the v2
documentation (`22-reference-tests.md`, `21-tests-et-ci.md`).

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

## Coming next

Not implemented yet. Listed so the gap is visible rather than assumed covered.

| Check | Idea | Defect it addresses |
|---|---|---|
| `compose config` | A configuration that does not parse installs nothing | The App Builder overlay enabled by default over a network nothing creates: `up -d` fails on a fresh install |
| `caddy validate` × 3 | Three TLS modes, three paths to exercise | A broken ingress mode discovered by the customer who uses it |
| `caddy adapt` | Either the domain is configurable or it is not | A broken interpolation: the six hostnames no longer match the real address |
| `shellcheck` | Shell fails quietly | Unknown — it has never been run against these three scripts |
| unit tests | Pure functions test without a machine | `env_set` does not recognise a commented-out variable and appends a duplicate |
| stubbed installer | Idempotence is proven, not promised | A leaking token, a second run that is not a no-op, a missing terminal |

## What this does not prove

These checks read files. They do not start anything.

They say nothing about whether the images pull, the containers start, the
inference serves, or the platform works. A green run means no known class of
defect was reintroduced — nothing more.

The tests that would prove more are described in the v2 documentation, and most
of them need a real GPU machine.
