# nemotron-3.5-bolt-74b on vLLM, GB10

| | |
|---|---|
| Image | `sha256:496fa5c9449c7d8613b3ddf73eb68feaaf9f6c76da78a6acb166047fd1e24cf5` (`engines/vllm:0.32.0rc1.dev100-b12x1.5.1`) |
| Family | `gb10`: NVIDIA GB10, arm64 |
| Box | a compute node, package `2026.10.0-rc8`, serving another box's platform through its inference surface |
| Date | 2026-10-20 |

Served model, read from the engine: `/v1/models` `nvidia/NVIDIA-Nemotron-3.5-Bolt-74B-A9B-24GB`. Started with
`HF_HUB_OFFLINE=1` from weights already in its cache volume: the 90 shards and the speculative draft
loaded in 151 s, 24.09 GiB, and the engine logged no download.

First token on a prompt of about 7,800 tokens, measured in the engine's container: 15.4 s for the
first request after start, then 5.93–5.98 s in the chat and Anthropic formats over three runs; the
first byte of the stream is the first token every time. The `time_to_first_token_seconds`
histogram has no bound between 1.0 and 2.5 s.

Through the inference surface: 401 without the key; with it, the platform's API and llm services
on the other box got an answer ("Paris"), trusting the node's root.

Restarted on `2026.10.0-rc9` the same day, it failed to start six times: with no
`--gpu-memory-utilization`, vLLM asks for 0.92 of the GPU, 111.95 GiB, and 111.2 to 111.9 GiB were
free. With 0.85 it started at the first attempt, healthy after about 7 minutes, with 71.9 GiB of KV
cache, 3.7 million tokens, 14 requests at the full 262,144-token context. The first-token figures
above were taken at 0.92 and not measured again.

Not measured here: tool calls, a restart with the network cut, a heavier load.
