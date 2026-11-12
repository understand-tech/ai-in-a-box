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
  be changeable in `local.env` and described in [docs/configuration.md](docs/configuration.md).
- **A saturated service refuses or queues, it does not fail.** Under more load than it can serve, a
  service answers with a bounded wait or a clean refusal the caller can retry, never an internal
  error; a service that restarts on its own is seen by the supervision and raises an alert, never
  silently.
- **Every service rotates its Docker logs** (`max-size` and `max-file`, or the `local` driver).
- **Every service has a healthcheck with a `start_period`,** and a service that needs another
  starts on `depends_on: condition: service_healthy`.
- **Databases and the inference engine get a `stop_grace_period`** long enough to stop cleanly.
- **Containers run as a non-root user,** `read_only` where they can, with `cap_drop` and
  `no-new-privileges`.
- **Redis has a `maxmemory`** and a policy that never evicts the task queue or the locks:
  `noeviction`, or eviction limited to the cache's keys that carry a TTL.
- **The inference engine is supervised** on its waiting requests, the filling of its KV cache, its
  preemptions and the time to the first token; its capacity settings (`gpu_memory_utilization`,
  `max_num_seqs`, `max_num_batched_tokens`) are measured per type of machine.
- **Every link between two machines of the product is encrypted, with a certificate on each side,**
  both signed by the `link` authority (see [docs/certificates-and-dns.md](docs/certificates-and-dns.md)); a
  surface that serves another machine requires and verifies the client's certificate. A link to what
  the product does not own (a browser, a backup destination, a public service) is HTTPS or SFTP,
  never plain. Between containers of one machine, an internal network and signed tokens are enough,
  unless a written decision says otherwise. A database connection that crosses a machine uses the
  database's own TLS, and the client verifies the server's certificate and name in full.
- **Each service has its own Postgres schema and role;** no role may create in `public`.

These rules describe the target: a change brings the services it touches in line with them.
- **Workflows and jobs:** `ci.yml` holds the checks of a pull request; a job is named by the guarantee it gives, a sentence in lower case ("the front door actually serves"); one job, `every check passed`, needs every other job of its workflow and is the only one branch protection requires, so that a job is renamed or added without touching the protection.
