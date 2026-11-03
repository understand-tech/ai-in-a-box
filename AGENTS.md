# Working on ai-in-a-box

What an AI agent, or a newcomer, needs before changing this repository, beyond what the
[README](README.md) and [docs/](docs/index.md) describe. When a change makes a line here wrong, fix it
in the same pull request.

## Rules for a change

- **This repository is public.** No customer name, no internal address, no private link, and never
  a flaw that could be exploited.
- **Settings, limits and sizes start from the component's published recommendations**, sized for the
  machine that runs them, from the smallest box to the largest server and the high-availability
  pair. The pull request names the source and the date it was read, and says where and why a value
  departs from it. No value is set by guess.
- **A claim about speed or quality rests on a measurement** made for it, never on an estimate.
- **Postgres is sized per type of machine from pgvector's and PgTune's recommendations:** shared
  buffers, effective cache size and the work memory for building an index follow the memory given to
  Postgres; the container's shared memory is at least the index build memory, or a parallel index
  build fails; index builds use the parallel workers the machine can give. Each value is meant to
  be changeable in `local.env` and described in [docs/configuration.md](docs/configuration.md); the
  service sets only its shared memory today, the rest is a rule for the settings to come.
- **A saturated service refuses or queues, it does not fail.** Under more load than it can serve, a
  service answers with a bounded wait or a clean refusal the caller can retry, never an internal
  error; a service that restarts on its own is seen by the supervision and raises an alert, never
  silently.
