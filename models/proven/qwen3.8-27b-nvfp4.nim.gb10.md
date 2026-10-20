# qwen3.8-27b-nvfp4 on NIM, GB10

| | |
|---|---|
| Image | `sha256:20e10652de4cf63d25417c0bcb0c35497b573cad575c3ba0a5296625c89b4bff` (model-free-nim 2.0.12) |
| Family | `gb10`: NVIDIA GB10, arm64, driver 580.142 |
| Box | the office's full-stack box, package `2026.10.0-rc7` |
| Date | 2026-10-20 |

Served model, read from the engine: manifest `Qwen3.8-27B-NVFP4`, `/v1/models` `Qwen/Qwen3.8-27B`.
The box has served it since 2026-10-14 without a restart of the engine, with
`--gpu-memory-utilization 0.55` instead of the entry's 0.75: it runs other services beside it.

First token on a prompt of about 7,800 tokens, measured in the engine's container: 6.08 s in the
chat format, 4.47 s in the Anthropic one; the first byte of the stream is the first token in both.
The `time_to_first_token_seconds` histogram has no bound between 1.0 and 2.5 s.

Not measured here: tool calls, a restart without network.
