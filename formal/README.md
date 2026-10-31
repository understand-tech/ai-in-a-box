# Formal models of the installer

Two models, each proved and replayed against the real `ut-install` cut before
every step.

## The database password rotation

`Rotation.lean` models what `ut-install` does when it changes the database
password (`step_rotate_a_published_database_password`, and
`put_the_old_database_password_back` when the change fails) and what the next
run does to finish a change that was cut off
(`step_finish_an_interrupted_database_password_change`).

A run can be cut at any step: Ctrl-C, a lost ssh session, a power cut. The
model replays the three ways a rotation goes — it succeeds, the services do not
come back, the database refuses the change — cut before each step, then the
next run. `RotationProofs.lean` states the rule they must all satisfy:

> After any cut and one more run, either local.env holds the password the
> database takes and the change record is gone, or the run stops with the
> record kept and local.env intact.

A cut before a step leaves nothing of it: `ut-install` replaces local.env and
.env by renaming a synced copy over them (`replace_file_with`), so a cut during
the write leaves the old content. Before that, `cat tmp > file` emptied the
file first, and this check found the cuts that left local.env empty.

## The settings migrated from main

`Settings.lean` models `migrate_existing_settings_into_local`, which splits
the `.env` of a checkout of `main` into `local.env` (the operator's values)
before `render_settings` rebuilds `.env` from `release.env` and `local.env`.
It carries one key of each kind main's `.env` holds — one only the operator
has, one the operator changed, one equal to the release's, an image the release
decides, and the `LOG_LEVEL=DEBUG` main shipped — and cuts the split before
each step. `SettingsProofs.lean` states the rule:

> After any cut and one more run, every setting compose reads is the one an
> uncut migration gives: the operator's values kept, the release's for the rest.

The next run splits again only while `local.env` is empty, so a `local.env`
written line by line and cut halfway is taken as complete.

## What each check does

The checks *database password rotation survives every cut* and *settings
migrated from main survive every cut* each:

1. Build their proof. A broken rule fails the check.
2. Write every cut to the run summary, ✅ or ❌, with what the next run leaves
   (`lake exe rotation_report`, `lake exe settings_report`). The report does
   not depend on the proof, so it still says which cut breaks the rule when the
   proof fails.
3. Print what the model expects after each cut (`rotation_cases`,
   `settings_cases`) and replay the same cut on the real `ut-install` functions
   (`test/database-rotation-cuts.sh`, `test/settings-migration-cuts.sh`),
   failing on any difference. That replay is what ties a model to the script: a
   change the model does not follow fails it.

## Locally

```sh
cd formal
lake build --wfail
lake exe rotation_report
lake exe rotation_cases | docker run --rm -i -v "$PWD/..":/w -w /w ubuntu:24.04 test/database-rotation-cuts.sh
lake exe settings_report
lake exe settings_cases | docker run --rm -i -v "$PWD/..":/w -w /w ubuntu:24.04 test/settings-migration-cuts.sh
```

The replays read `/proc`, so it needs Linux. Lean installs with
[elan](https://github.com/leanprover/elan); `lean-toolchain` sets the version.
