# Formal model of the database password rotation

`Rotation.lean` models what `ut-install` does when it changes the database
password (`step_rotate_a_published_database_password`, and
`put_the_old_database_password_back` when the change fails) and what the next
run does to finish a change that was cut off
(`step_finish_an_interrupted_database_password_change`).

A run can be cut at any step: Ctrl-C, a lost ssh session, a power cut. The
model replays the three ways a rotation goes — it succeeds, the services do not
come back, the database refuses the change — cut before each step, then the
next run. `Proofs.lean` states the rule they must all satisfy:

> After any cut and one more run, either local.env holds the password the
> database takes and the change record is gone, or the run stops with the
> record kept and local.env intact.

A cut before a step leaves nothing of it: `ut-install` replaces local.env and
.env by renaming a synced copy over them (`replace_file_with`), so a cut during
the write leaves the old content. Before that, `cat tmp > file` emptied the
file first, and this check found the cuts that left local.env empty.

## What the `database password rotation` check does

1. Builds the proof. A broken rule fails the check.
2. `lake exe rotation_report` writes every cut to the run summary, ✅ or ❌,
   with what the next run leaves. It does not depend on the proof, so it still
   says which cut breaks the rule when the proof fails.
3. `lake exe rotation_cases` prints what the model expects after each cut, and
   `test/database-rotation-cuts.sh` replays the same cut on the real
   `ut-install` functions — database, compose and backups faked — and fails on
   any difference. That replay is what ties the model to the script: a change
   to the rotation that the model does not follow fails it.

## Locally

```sh
cd formal
lake build --wfail
lake exe rotation_report
lake exe rotation_cases | docker run --rm -i -v "$PWD/..":/w -w /w ubuntu:24.04 test/database-rotation-cuts.sh
```

The replay reads `/proc`, so it needs Linux. Lean installs with
[elan](https://github.com/leanprover/elan); `lean-toolchain` sets the version.
