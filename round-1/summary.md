# deepseek-v4-flash-0731 on SWE-bench Verified

## Summary

An end-to-end SWE-bench Verified run of deepseek-v4-flash-0731 (a 2-bit quantized model) served by ds4-server 0.5.4 on a single Nvidia DGX Spark. 500 problems, 4 days of wall clock time.

- **Score:** 290 / 500 submitted = **58.1%**
- **Period:** 2026-08-05 18:26 EST – 2026-08-09 19:33 EST (4 days 1 hour 7 mins)
- **Inference server:** ds4-server 0.5.4
- **Bench runner:** mini-swe-agent, 3 workers

## Result Breakdown

```
500 (100%)                      total
    ├── 500 (100%)              submitted
    │   ├── 291 (58%)           resolved --> score 291/500 = 58.2%
    │   ├── 58 (12%)            unresolved
    │   └── 151 (30%)           failed
    │       ├── 0 (0%)          server-error
    │       ├── 109 (22%)       client-error
    │       │   ├── 71 (14%)    repeated-format-error
    │       │   └── 38 (8%)     step-limit-exceeded
    │       └── 42 (8%)         unknown
    └── 0 (0%)                  unsubmitted
```

## Caveats

The run is not strictly clean.

- **Server restarts (~23 total)** — the original bench protocol forbids server restarts. They were unavoidable here:
  - ~5 manual restarts to recover `illegal memory access` crashes.
  - ~18 auto restarts by a watchdog to recover `CUDA prefill error`.
  - Both crash modes were fixed in ds4-server 0.5.6 (released after this run).
- **30% of submissions failed**, mostly format errors and step-limit exhaustion. The `unknown` failures (42) were not classified.

## Setup

### Model & server

| | |
|---|---|
| Model | deepseek-v4-flash-0731 (2-bit) |
| Server | ds4-server 0.5.4 |
| GPU | 1× Nvidia DGX Spark |
| Driver/runtime | WSL2 on Windows 10 PC |

### ds4-server launch command

```sh
export DS4_CUDA_NO_HBM_CACHE=1
export DS4_SERVER_COALESCE_MAX=3
export DS4_SERVER_DEFAULT_TEMP=0
export DS4_BATCH_FIT_HEADROOM_MB=2048
export DS4_SESSION_GRAPH_HEADROOM_MB=512
export DS4_SESSION_LAZY_GRAPH=0
unset DS4_MODEL_ANON_HUGE
unset DS4_CUDA_Q8_F16_PRELOAD DS4_CUDA_Q8_F32_PRELOAD

watchdog ds4-serve -c 196608 --host 0.0.0.0 --port 8000 \
    --tokens 8192 --mem-floor-gb 1 --no-dspark --reasoning-effort low
```

### mini-swe-agent bench command

```sh
docker run hello-world
uv --version
uv run --python 3.14 --with mini-swe-agent \
    python -m minisweagent.run.benchmarks.swebench \
    --subset verified --split test \
    --model openai/deepseek-v4-flash \
    --output ./predictions -w 3
```

## Why this configuration

A 2-bit model has tight memory pressure, and most of the tuning trades capacity for headroom and stability.

### Capacity choices

The model weights and KV cache together exceed the DGX Spark's memory once long contexts are involved. The following were disabled to claw back ~21 GB of RAM for longer context:

| Disabled | Saved |
|---|---|
| HBM cache (`DS4_CUDA_NO_HBM_CACHE=1`) | ~8 GB |
| Q8 F16/F32 preload caches | ~6 GB |
| DSpark speculative decoding model (`--no-dspark`) | ~7 GB |

OS-side:

- GNOME unloaded (~0.5 GB reclaimed).

### Stability choices

Aimed at preventing OOM and the two crash classes that triggered restarts:

- `DS4_SERVER_COALESCE_MAX=3` (down from default 32) — lower concurrency, fewer concurrent graphs.
- `DS4_BATCH_FIT_HEADROOM_MB=2048` (down from 8 GB) — more room for sessions.
- `DS4_SESSION_GRAPH_HEADROOM_MB=512` (down from 1 GB) — fewer "graph-something" errors.
- `DS4_SESSION_LAZY_GRAPH=0` — pre-allocate session graphs to avoid runtime OOM.
- `--mem-floor-gb 1` (down from 4 GB) — more addressable RAM for long contexts.
- `--tokens 8192` (up from 4 k) — reduce per-step errors caused by token-size limits.
- Custom `watchdog` script — auto-restart on `CUDA prefill error`. A few manual restarts covered `illegal memory access`, which the watchdog did not catch.

### Capacity & determinism

- `-c 196608` — context length raised from 32 k to 192 k to fit the longer SWE-bench trajectories.
- `DS4_SERVER_DEFAULT_TEMP=0` — for maximum determinism.

### Worker count

- `-w 3` workers on the agent side, matched to `DS4_SERVER_COALESCE_MAX=3` to keep one request per server slot.

## Notes

- 23 server restarts is the largest confound. A clean re-run on ds4-server 0.5.6+ should reduce both the restart count and possibly the 30% failure rate, since many of the `client-error` and `unknown` failures appear tied to the same crash modes.
- 38 step-limit-exceeded failures suggest the agent budget may be tighter than the model's effective reasoning depth on harder problems; worth a follow-up.
- 71 repeated-format-error failures are the biggest single failure bucket and likely the most actionable to fix on the agent side.

## Plan for round 2

- Will try the 151 failures (30%) again with better configuration.
- Upgrade ds4-server 0.5.4 to 0.5.6 (or the latest) for stability.
- Increase context length 192k to 384k (or 512k) to enable reasoning effort `high`. If this causes OOM, will try disable the MTP speculative decoding which will give me ~7GB back.
