#!/bin/bash -x
# 192k ctx / reasoning low / banks=3 / graph headroom 256MB / MTP spec ON / HBM cache OFF / CUDA watchdog
me=$(basename "$0" .sh)
export PATH="$HOME/.local/bin:$HOME/bin:$PATH"

# HBM cache OFF
export DS4_CUDA_NO_HBM_CACHE=1

# Banks=3 and headroom (fit 2048MB / graph 256MB)
export DS4_SERVER_COALESCE_MAX=3
export DS4_SERVER_DEFAULT_TEMP=0
export DS4_BATCH_FIT_HEADROOM_MB=2048
export DS4_SESSION_GRAPH_HEADROOM_MB=256

# Lazy session graph OFF
export DS4_SESSION_LAZY_GRAPH=0

# Q8 preload OFF
unset DS4_MODEL_ANON_HUGE
unset DS4_CUDA_Q8_F16_PRELOAD DS4_CUDA_Q8_F32_PRELOAD

# ds4-serve wrapped in CUDA watchdog (auto-restart on CUDA prefill error /
# illegal memory access). Watchdog logs to tmp.<me>.watchdog.log; ds4-serve
# stdout/stderr is also captured to tmp.<me>.log for triage.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WATCHDOG_LOG="tmp.${me}.watchdog.log"
exec "$SCRIPT_DIR/watchdog.sh" ds4-serve \
    -c 196608 --host 0.0.0.0 --port 8000 \
    --tokens 8192 --mem-floor-gb 1 --no-dspark --reasoning-effort low \
    > "tmp.${me}.log" 2>&1