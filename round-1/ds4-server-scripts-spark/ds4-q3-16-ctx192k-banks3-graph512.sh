#!/bin/bash -x
# ============================================================================
# ds4-q3-16-ctx192k-banks3-graph512.sh — config 16 (full restore of config 12)
# 192k ctx / reasoning low / banks=3 / fit 2048MB / graph 512MB / MTP spec ON
# ============================================================================
export PATH="$HOME/.local/bin:$HOME/bin:$PATH"
# Engine source path is environment-dependent; override via DS4_SERVER_DIR
# (default: $HOME/src/inference-engines/ds4-server)
DS4_SERVER_DIR="${DS4_SERVER_DIR:-$HOME/src/inference-engines/ds4-server}"
cd "$DS4_SERVER_DIR" || { echo "ERROR: DS4_SERVER_DIR=$DS4_SERVER_DIR not found" >&2; exit 1; }

# HBM cache OFF — prevents the 65k context lock-up
export DS4_CUDA_NO_HBM_CACHE=1

# Banks=3 and headroom (fit 2048MB / graph 512MB — config 12 verified values)
export DS4_SERVER_COALESCE_MAX=3
export DS4_SERVER_DEFAULT_TEMP=0
export DS4_BATCH_FIT_HEADROOM_MB=2048
export DS4_SESSION_GRAPH_HEADROOM_MB=512

# Pre-allocate session graph at boot (disable the lazy path)
export DS4_SESSION_LAZY_GRAPH=0

unset DS4_MODEL_ANON_HUGE
unset DS4_CUDA_Q8_F16_PRELOAD DS4_CUDA_Q8_F32_PRELOAD

# ds4-serve wrapped in CUDA watchdog (MTP spec ON, DSpark OFF, mem-floor-gb 1).
# Watchdog auto-restarts on CUDA prefill error / illegal memory access.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
"$SCRIPT_DIR/watchdog.sh" ds4-serve \
    -c 196608 \
    --host 0.0.0.0 \
    --port 8000 \
    --tokens 8192 \
    --mem-floor-gb 1 \
    --no-dspark \
    --reasoning-effort low > tmp.ds4-q3-16-ctx192k-banks3-graph512.sh.log