# nvidia-nemotron-3.5-bolt-e4b-bf16-nim on NIM, GB10

| | |
|---|---|
| Image | `sha256:20e10652de4cf63d25417c0bcb0c35497b573cad575c3ba0a5296625c89b4bff` | (the box ran `sha256:8d3913d496d6e2943a3a1f8b0330b3b85a340271d30f7bf6415d3ccaf3d20bb1`, its platform's)
| Family | `gb10` |
| Engine | vllm 0.27.1 |
| Date | 2026-10-27 |

Served model, read from the engine before every measure: `nvidia/NVIDIA-Nemotron-3.5-Bolt-E4B-BF16`.

Usages held within their latency budget, the two passes agreeing: `chat`, `rag`.

Evaluated on: `code`, `instruction-following`, `reasoning`, `tool-calling`.
