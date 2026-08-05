#!/bin/bash
set -eo pipefail

# LLM 서버 위치는 환경마다 다르므로 LLM_BASE_URL 로 오버라이드 가능 (기본은 DGX Spark 의 ds4-serve)
LLM_BASE_URL="${LLM_BASE_URL:-http://spark1.local:8000/v1}"
export OPENAI_API_BASE="$LLM_BASE_URL"
export OPENAI_API_KEY="none"
export MSWEA_COST_TRACKING="ignore_errors"

LOG_FILE="benchmark_timing.log"

log() {
    local msg="[$(date '+%Y-%m-%d %H:%M:%S')] $1"
    echo "$msg"
    echo "$msg" >> "$LOG_FILE"
}

time_step() {
    local label="$1"
    shift
    log "Starting ${label}"
    local start_time=$(date +%s)
    "$@"
    local elapsed=$(( $(date +%s) - start_time ))
    log "${label} Completed. Elapsed Time: ${elapsed}s ($((elapsed / 60))m $((elapsed % 60))s)"
}

log "=========================================="
log "Starting SWE-bench Verified Pipeline"
log "=========================================="

# arg1 = mini-swe-agent -w (inference parallelism). 기본값 3.
# 예: ./run-swebench-verified.sh 3   (q12 구성에서 사용 예정)
INFERENCE_WORKERS="${1:-3}"
log "inference parallelism (-w) = ${INFERENCE_WORKERS}"

echo "+ Checking local LLM model status..."
curl -s "$LLM_BASE_URL/models" | jq

START_TIME=$(date +%s)

# 1. Sequential Step 1: LLM Inference
set -x
time_step "Step 1: LLM Inference" python -m minisweagent.run.benchmarks.swebench \
    --subset verified \
    --split test \
    --model openai/deepseek-v4-flash \
    --output ./predictions \
    -w "$INFERENCE_WORKERS"
set +x

# 2. Sequential Step 2: Evaluation
time_step "Step 2: Harness Evaluation" ./eval-swebench-verified.sh ./predictions/predictions.jsonl exp_local_llm 4

TOTAL_DURATION=$(( $(date +%s) - START_TIME ))
log "=========================================="
log "SWE-bench Verified Pipeline Finished"
log "Total Elapsed Time: ${TOTAL_DURATION}s ($((TOTAL_DURATION / 60))m $((TOTAL_DURATION % 60))s)"
log "=========================================="

