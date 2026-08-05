#!/bin/bash -x
# 192k ctx / reasoning low / 뱅크 3개 / Graph Headroom 256MB / MTP spec ON / HBM 캐시 OFF / CUDA watchdog
me=$(basename $0 .sh)
export PATH="$HOME/.local/bin:$HOME/bin:$PATH"

# HBM 캐시 OFF
export DS4_CUDA_NO_HBM_CACHE=1

# 뱅크 3개 & 헤드룸 (Fit 2048MB / Graph 256MB)
export DS4_SERVER_COALESCE_MAX=3
export DS4_SERVER_DEFAULT_TEMP=0
export DS4_BATCH_FIT_HEADROOM_MB=2048
export DS4_SESSION_GRAPH_HEADROOM_MB=256

# Lazy Graph OFF
export DS4_SESSION_LAZY_GRAPH=0

# Q8 Preload OFF
unset DS4_MODEL_ANON_HUGE
unset DS4_CUDA_Q8_F16_PRELOAD DS4_CUDA_Q8_F32_PRELOAD

# ds4-serve wrapped in CUDA watchdog (auto-restart on illegal memory access)
ds4-serve -c 196608 --host 0.0.0.0 --port 8000 --tokens 8192 --mem-floor-gb 1 --no-dspark --reasoning-effort low | tee -a tmp.$me.log

