# DeepSeek-V4-Flash-0731 on Single DGX Spark

Benchmarking deepseek-v4-flash-0731 (a 2-bit quantized model) on SWE-bench Verified, served by `ds4-serve` on a single Nvidia DGX Spark.

## Round 1

- **Score:** 58.2% (291 / 500)
- 151 of 500 failed (30%).
- See the summary at [round-1/summary.md](round-1/summary.md).
- Find all test trajectories at `round-1/predictions/`.

## Round 2 (planned)

Retry only the 151 failures from Round 1 with a revised configuration:

- Upgrade ds4-server from 0.5.4 to 0.5.6+ for stability.
- Increase context length from 192k to 384k (or 512k) to enable `reasoning-effort high`. If this causes OOM, disable the MTP speculative decoding model to reclaim ~7 GB.