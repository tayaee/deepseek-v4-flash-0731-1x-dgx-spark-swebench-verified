#!/bin/bash -x
# ============================================================================
# ds4-q3-16-ctx192k-banks3-graph512.sh (구성 16 — 구성 12 완전 원복 스크립트)
# 192k ctx / reasoning low / 뱅크 3개 / Fit 2048MB / Graph 512MB / MTP spec ON
# ============================================================================
export PATH="$HOME/.local/bin:$HOME/bin:$PATH"
# 엔진 소스 위치는 환경마다 다르므로 DS4_SERVER_DIR 로 오버라이드 가능 (기본은 $HOME/src/inference-engines/ds4-server)
DS4_SERVER_DIR="${DS4_SERVER_DIR:-$HOME/src/inference-engines/ds4-server}"
cd "$DS4_SERVER_DIR" || { echo "ERROR: DS4_SERVER_DIR=$DS4_SERVER_DIR not found" >&2; exit 1; }

# [HBM 캐시 OFF] HBM 캐시 OFF로 65k 락업 방지
export DS4_CUDA_NO_HBM_CACHE=1

# --- 뱅크 3개 & 헤드룸 (Fit 2048MB / Graph 512MB - 구성 12 검증값 원복) ---
export DS4_SERVER_COALESCE_MAX=3
export DS4_SERVER_DEFAULT_TEMP=0
export DS4_BATCH_FIT_HEADROOM_MB=2048
export DS4_SESSION_GRAPH_HEADROOM_MB=512

# 부팅 시점에 session graph 를 pre-alloc (lazy 경로 제거)
export DS4_SESSION_LAZY_GRAPH=0

unset DS4_MODEL_ANON_HUGE
unset DS4_CUDA_Q8_F16_PRELOAD DS4_CUDA_Q8_F32_PRELOAD

# ds4-serve wrapped in CUDA watchdog (MTP spec ON, DSpark OFF, mem-floor-gb 1)
ds4-serve \
    -c 196608 \
    --host 0.0.0.0 \
    --port 8000 \
    --tokens 8192 \
    --mem-floor-gb 1 \
    --no-dspark \
    --reasoning-effort low > tmp.ds4-q3-16-ctx192k-banks3-graph512.sh.log

