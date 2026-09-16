# Observability

Observability stack for the Understand Tech on-prem inference boxes — Prometheus,
Grafana and a set of exporters (NVIDIA DCGM, node-exporter, cAdvisor), wired to
the NIM/vLLM engines and the ut-api LLM gateway.

It exists to answer one question fast: **is the box hung, or is it saturated?**
Those look identical to a user (a request that never comes back) and have opposite
fixes. The dashboard and alerts here separate them — and since the gateway grew
admission controls (prompt cap, per-key and per-user rate limits), they also show
**who** is loading the box and **which protections are firing**.

## The signal that matters

`vllm:num_requests_waiting > 0`

When that is non-zero, every new request is queued behind work already on the GPU.
Nothing is broken — the box is at capacity, usually from long-context traffic — but
clients will time out and report a "hang". A sustained queue is the exact moment
users feel it, which is why it drives the headline dashboard tile and the first alert.

An actual outage looks different: `up{job="vllm"} == 0`, covered by `LLMTargetDown`.

## Stack

| Service | Image | Port | Notes |
|---|---|---|---|
| Prometheus | `prom/prometheus:v2.53.0` | 9090 | 15-day retention, 5s scrape on the engines |
| Grafana | `grafana/grafana:11.1.0` | 3000 | Dashboards auto-provisioned, anonymous viewer enabled |
| DCGM exporter | `nvcr.io/nvidia/k8s/dcgm-exporter:3.3.7-3.5.0-ubuntu22.04` | 9400 | GPU util / bandwidth / VRAM / temp / power; custom counter set (`dcgm-counters.csv`) |
| node-exporter | `prom/node-exporter:v1.8.2` | 9100 | Host CPU / memory / disk |
| cAdvisor | `gcr.io/cadvisor/cadvisor:v0.49.1` | 8080 | Per-container stats + restart detection |

All images are multi-arch (arm64 OK on GB10/Grace/GB300). Runs as its own compose
project (`ut-monitoring`) and *joins* the platform's existing networks rather than
creating them, so the main `compose.yaml` stays untouched.

## Scrape targets

| Job | Target | Needs |
|---|---|---|
| `vllm` | nim-llm:8000, nim-vlm:8000 | nothing (built into NIM) |
| `dcgm` | dcgm-exporter:9400 | NVIDIA Container Toolkit |
| `gateway` | ut-api:8501, ut-api-customer:8501 | a ut-api image with `llm_gateway/prom.py` (staging_aws ≥ 2026-09-15) |
| `node` | node-exporter:9100 | nothing |
| `cadvisor` | cadvisor:8080 | nothing |
| `caddy` | ut-caddy:2019 | `servers { metrics }` in the Caddyfile global options — **shows DOWN until enabled, by design** |

## Prerequisites

- The platform stack is already up (`docker compose up -d` at the repository
  root), so the external networks `ut-backend-network` and `ut-frontend-network`
  exist.
- `COMPOSE_PROFILES` includes `nim`, so `nim-llm` and `nim-vlm` are running and
  resolvable by DNS on the backend network. Without them the `vllm` targets stay
  `DOWN` and the dashboard is empty; adjust the targets in `prometheus.yml` if the
  box serves other engines.
- NVIDIA Container Toolkit installed, for the DCGM exporter's GPU access.

## Quick start

```bash
cd monitoring
docker compose -f docker-compose.monitoring.yml up -d
```

Then open:

- **Grafana** — `http://<box>:3000` → dashboard *UAI Inference Observability*
  (folder "Understand Tech"). Login `admin` / `utmonitor`.
- **Prometheus** — `http://<box>:9090` → check *Status → Targets* first; every job
  except `caddy` should be `UP` before the dashboard means anything.

> **Change the Grafana password before exposing the box.** `utmonitor` is a
> placeholder default set in `docker-compose.monitoring.yml`
> (`GF_SECURITY_ADMIN_PASSWORD`). Anonymous read-only viewing is on by default too —
> turn off `GF_AUTH_ANONYMOUS_ENABLED` if the box is reachable beyond your network.

## Dashboard

*UAI Inference Observability* (uid `uai-inference`), refreshing every 10s. It reads
top-down as a story; deep-dive rows are **collapsed** (click a row title to expand)
so the first screen answers 90% of questions. Red always means the bad thing; hover
any panel's `ⓘ` for how to read it. Shared crosshair is on — hover one graph and
the cursor lines up across all of them.

**Always visible:**

1. **🚦 Health tiles** — WAITING (red background ≥ 1 = users see a "hang"),
   running, queue-wait p95, GPU util, KV cache, MTP acceptance, alerts firing.
2. **🧭 Saturation** — running vs WAITING, and queue wait time (p95 + average)
   with 5s/30s guide lines.
3. **⏱ Latency & throughput** — TTFT & e2e p95, streaming speed, token load
   (prompt tok/s is the *cause*; spikes here precede WAITING).
4. **🛡 Gateway protections** — cap 400s & rate-limit 429s per minute, traffic by
   model, **Top API keys** and **Top users** leaderboards (in-cell bars scaled to
   the 30/min limit), prompt size vs the 65536 cap line, HTTP outcomes.

**Collapsed deep dives:** 🔬 Engine (prefill vs decode, engine-side prompt sizes,
finish reasons, KV & preemptions, batch concurrency, MTP trend) · 🎛 GPU (DRAM
bandwidth — the true decode bottleneck, SM/tensor activity, VRAM, thermals) ·
🖥 Host (CPU avg + hottest core, memory & disk, container restarts) ·
🩺 Monitoring health (targets up, alert history).

## Alerts

Defined in `alerts.yml`, evaluated by Prometheus every 15s.

| Alert | Fires when | Severity | Means |
|---|---|---|---|
| `LLMRequestsQueueing` | `vllm:num_requests_waiting > 0` for 2m | warning | Capacity saturated; new requests look hung |
| `LLMKVCachePressure` | KV cache > 90% for 5m | warning | Preemption/recompute thrash imminent |
| `LLMTargetDown` | `up{job="vllm"} == 0` for 1m | critical | Engine unreachable — a real outage |
| `GatewayCapRejectionsSpike` | >10 cap 400s/min for 10m | warning | Cap too tight, or a client not compacting |
| `GatewayRateLimitSpike` | >20 429s/min for 10m | warning | A key hammering the box, or limits too strict |
| `GPUHot` | GPU > 85°C for 5m | warning | Thermal throttling imminent |
| `HostDiskLow` | a filesystem < 10% free for 15m | warning | Weight caches fill disks fast |
| `ContainerRestarted` | key container restarted in 15m | info | Deploy blip — or a crash loop if repeated |
| `MonitoringTargetDown` | any exporter down 5m (excl. vllm/caddy) | warning | The stack is partially blind |

Prometheus evaluates these but does not route them. To get notified, point an
Alertmanager at this instance and wire `LLMRequestsQueueing` to Slack or email —
it is the one worth waking up for.

## Layout

```
.
├── docker-compose.monitoring.yml   # the stack (prom, grafana, dcgm, node, cadvisor)
├── prometheus.yml                  # scrape config (engines & dcgm @ 5s, rest @ 15s)
├── alerts.yml                      # saturation / gateway / hardware rules
├── dcgm-counters.csv               # DCGM counter set (adds PROF bandwidth + VRAM fields)
└── grafana/
    ├── dashboards/
    │   └── nim-observability.json  # UAI Inference Observability (41 panels)
    └── provisioning/
        ├── dashboards/provider.yml # auto-load from disk
        └── datasources/prometheus.yml
```

Dashboards and datasources are provisioned from disk, so edits made in the Grafana
UI are not persisted. Change the JSON here and redeploy — that keeps every box
identical and the config reviewable.

## Operating notes

- **Data** lives in named volumes `ut-prometheus-data` and `ut-grafana-data`;
  `docker compose down` keeps them, `down -v` destroys the history.
- **Retention** is 15 days (`--storage.tsdb.retention.time`). Raise it if you want
  to compare against load tests from further back.
- **Scrape interval** on the engines is 5s, deliberately tighter than the 15s global
  default, so the onset of saturation is sharp rather than smeared.
- **After changing configs**: `docker compose -f docker-compose.monitoring.yml up -d`
  for new/changed services, `docker restart ut-grafana` for dashboard JSON. For
  `prometheus.yml`/`alerts.yml`, `docker exec ut-prometheus kill -HUP 1` reloads —
  **but only if the file was edited in place**. Replacing it (scp, `mv`) swaps the
  inode behind the single-file bind mount and the container keeps reading the old
  content: use `up -d --force-recreate prometheus` after any copy-based update.

## Troubleshooting

| Symptom | Check |
|---|---|
| vLLM targets `DOWN` | Container DNS names in `prometheus.yml`; is the monitoring project on the same network as the NIMs? |
| DCGM target `DOWN` | NVIDIA Container Toolkit installed; `SYS_ADMIN` capability granted; GPUs visible to Docker; `dcgm-counters.csv` present next to the compose file (a missing file becomes an empty **directory** at container start and crash-loops the exporter) |
| `gateway` targets `DOWN` | The api containers must run an image containing `app/routers/llm_gateway/prom.py` (`docker exec ut-api ls app/routers/llm_gateway/ \| grep prom`) |
| `caddy` target `DOWN` | Expected until the Caddyfile enables `servers { metrics }` |
| GPU bandwidth / SM / VRAM panels empty | The GB10 iGPU exposes neither DCGM profiling (PROF) nor framebuffer fields — those panels are for discrete-class GPUs (GB300); on the GB10 the Host memory panel *is* the GPU memory (unified) |
| Queue wait p95 flat at exactly 285ms | Histogram floor, not a measurement: the smallest bucket is 0.3s, so "everything under it" interpolates to 0.95 × 300ms. It means **no queueing**; the `avg` series shows the true value |
| Top users table empty | The gateway only records `acting_user` from keys listed in its `GATEWAY_TRUSTED_PROXY_KEYS` (the app builder's key); CLI traffic appears under Top API keys instead |
| Config edits not taking effect | The bind-mount inode trap — see Operating notes; `--force-recreate` the service |
| Dashboard empty but targets `UP` | Engines expose `vllm:*` metrics only once they have served traffic — send a request |
| Grafana edits disappear | Expected — dashboards are provisioned read-only from `grafana/dashboards/` |

## Multi-box

Run this same stack on every box (each box's Grafana shows its own values). For one
global view later: add `external_labels: {box: <name>}` under `global:` in each
box's `prometheus.yml` and federate them into a central Prometheus — the dashboard
queries then group by `box`.
