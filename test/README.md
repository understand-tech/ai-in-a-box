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

| Check | Catches |
|---|---|
| `plaintext-secret` | `.env.example` shipped a real `JWT_SECRET`, shared by four services — a token minted at one customer was accepted at another. Plus seven other values that read as configured and were therefore never changed. |
| `undeclared-variable` | A compose file referencing `${VAR}` with no default, where `.env.example` does not define it — the stack starts with the value empty. Only variables without a default are checked; a `${VAR:-default}` needs no entry. |
| `unlisted-port` | MongoDB and both NIM containers published their ports on every interface. Publications bound to `127.0.0.1` are ignored: they expose nothing, so they need no authorisation. |
| `unpinned-image` | Mutable tags like `2.0-arm64`, so two boxes on "the same version" could differ and a diagnosis on one did not transfer to another. |
| `verbose-log-level` | `LOG_LEVEL=DEBUG` shipped as the default, on a customer's appliance. |
| `queue-eviction` | Redis holding the RQ queues while running `allkeys-lru`, so tasks could be evicted under memory pressure. |
| `missing-documented-path` | Preventive, and the only one here that has caught nothing yet: a file renamed without updating the README. |

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

## What this does not prove

These checks read files. They do not start anything.

They say nothing about whether the images pull, the containers start, the
inference serves, or the platform works. A green run means no known class of
defect was reintroduced — nothing more.

The tests that would prove more are described in the v2 documentation, and most
of them need a real GPU machine.
