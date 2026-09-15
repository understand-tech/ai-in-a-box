# Observability

Observability stack for the Understand Tech on-prem inference boxes — Prometheus,
Grafana and the NVIDIA DCGM exporter, wired to the NIM/vLLM engines.

It exists to answer one question fast: **is the box hung, or is it saturated?**
Those look identical to a user (a request that never comes back) and have opposite
fixes. The dashboard and alerts here separate them.

## The signal that matters

`vllm:num_requests_waiting > 0`

When that is non-zero, every new request is queued behind work already on the GPU.
Nothing is broken — the box is at capacity, usually from long-context traffic — but
clients will time out and report a "hang". A sustained queue is the exact moment
users feel it, which is why it drives both the headline dashboard panel and the
first alert.

An actual outage looks different: `up{job="vllm"} == 0`, covered by `LLMTargetDown`.

## Stack

| Service | Image | Port | Notes |
|---|---|---|---|
| Prometheus | `prom/prometheus:v2.53.0` | 9090 | 15-day retention, 5s scrape on the engines |
| Grafana | `grafana/grafana:11.1.0` | 3000 | Dashboards auto-provisioned, anonymous viewer enabled |
| DCGM exporter | `nvcr.io/nvidia/k8s/dcgm-exporter:3.3.7-3.5.0-ubuntu22.04` | 9400 | GPU util / memory / power, multi-arch (arm64 OK on GB10/Grace) |

Runs as its own compose project (`ut-monitoring`) and *joins* the platform's existing
networks rather than creating them, so the main `compose.yaml` stays untouched.

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
  should be `UP` before the dashboard means anything.

> **Change the Grafana password before exposing the box.** `utmonitor` is a
> placeholder default set in `docker-compose.monitoring.yml`
> (`GF_SECURITY_ADMIN_PASSWORD`). Anonymous read-only viewing is on by default too —
> turn off `GF_AUTH_ANONYMOUS_ENABLED` if the box is reachable beyond your network.

## Dashboard

*UAI Inference Observability* (uid `uai-inference`), refreshing every 10s.

**Top row, at-a-glance:** requests running · requests waiting · GPU util · KV cache
used · MTP acceptance.

**Timelines, in diagnostic order:**

1. **Saturation** — running vs waiting. Waiting above zero is the "hang".
2. **Latency** — TTFT and end-to-end p95. The symptom users describe.
3. **Token load** — prompt tokens/s. The *cause*: context pressure.
4. **KV cache % & preemptions** — pressure turning into recompute thrash.
5. **GPU util & power** — DCGM, confirming the hardware is genuinely pegged.

Read it top to bottom: symptom, then cause, then confirmation.

## Alerts

Defined in `alerts.yml`, evaluated by Prometheus every 15s.

| Alert | Fires when | Severity | Means |
|---|---|---|---|
| `LLMRequestsQueueing` | `vllm:num_requests_waiting > 0` for 2m | warning | Capacity saturated; new requests look hung |
| `LLMKVCachePressure` | `vllm:kv_cache_usage_perc > 0.90` for 5m | warning | Preemption/recompute thrash imminent |
| `LLMTargetDown` | `up{job="vllm"} == 0` for 1m | critical | Engine unreachable — a real outage |

Prometheus evaluates these but does not route them. To get notified, point an
Alertmanager at this instance and wire `LLMRequestsQueueing` to Slack or email —
it is the one worth waking up for.

## Layout

```
.
├── docker-compose.monitoring.yml   # the stack
├── prometheus.yml                  # scrape config (engines @ 5s, DCGM @ 5s)
├── alerts.yml                      # saturation + outage rules
└── grafana/
    ├── dashboards/
    │   └── nim-observability.json  # UAI Inference Observability
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

## Troubleshooting

| Symptom | Check |
|---|---|
| vLLM targets `DOWN` | Container DNS names in `prometheus.yml`; is the monitoring project on the same network as the NIMs? |
| DCGM target `DOWN` | NVIDIA Container Toolkit installed; `SYS_ADMIN` capability granted; GPUs visible to Docker |
| Dashboard empty but targets `UP` | Engines expose `vllm:*` metrics only once they have served traffic — send a request |
| Grafana edits disappear | Expected — dashboards are provisioned read-only from `grafana/dashboards/` |
