#!/bin/bash
# stop-swebench.sh
#   - 진행 중인 mini-swe-agent / swebench harness 컨테이너를 모두 중지 및 삭제
#   - 이미지는 유지 (재사용을 위해 — swebench 이미지는 수 GB이므로 매번 pull 하지 않음)
#   - preds.json / traj.json은 건드리지 않음 → 다음 실행 시 incremental 재개 가능
#
# ⚠️  incremental 동작 미묘한 점 (mini-swe-agent 기준):
#   - preds.json에 있는 instance: 다음 실행 시 자동으로 스킵됨 (main()의 `existing_instances` 체크)
#   - 진행 중이던 instance (컨테이너 띄운 후 LLM 응답 대기/실행 중): preds.json에 없으므로
#     "처음부터 다시 실행" 됨 — process_instance() 진입 시 remove_from_preds_file() +
#     traj.json unlink() 가 일어나기 때문
#   - 즉 "preds.json에 들어간 instance만" incremental 보장됨

set -eo pipefail

LOG_FILE="benchmark_timing.log"

log() {
    local msg="[$(date '+%Y-%m-%d %H:%M:%S')] $1"
    echo "$msg"
    echo "$msg" >> "$LOG_FILE"
}

PATTERN='(swebench|sweb\.eval|minisweagent)'

log "=========================================="
log "Stopping swebench-related containers"
log "=========================================="

# 사전 검사
if ! command -v docker >/dev/null 2>&1; then
    log "ERROR: docker command not found"
    exit 1
fi
if ! docker info >/dev/null 2>&1; then
    log "ERROR: docker daemon not reachable"
    exit 1
fi

# 매칭 컨테이너 찾기 (실행 중 + 정지된 것 모두)
MATCHING=$(docker ps -a --format "{{.ID}}	{{.Names}}	{{.Image}}	{{.Status}}" \
    | { grep -iE "$PATTERN" || true; })

if [ -z "$MATCHING" ]; then
    log "No swebench-related containers found."
    exit 0
fi

echo ""
echo "=== Matching containers ==="
echo "$MATCHING" | column -t -s $'	' 2>/dev/null || echo "$MATCHING"

IDS=$(echo "$MATCHING" | cut -f1)
RUNNING_IDS=$(echo "$MATCHING" | awk -F'	' '$4 ~ /^Up/ {print $1}')

N_TOTAL=$(echo "$IDS" | wc -l)
N_RUNNING=$(echo "$RUNNING_IDS" | { [ -n "$RUNNING_IDS" ] && wc -l || echo 0; } | tr -d ' ')
log "Found ${N_TOTAL} containers (running: ${N_RUNNING})"

# 1) 실행 중인 컨테이너 stop — mini-swe-agent 컨테이너는 `--rm`으로 띄워져 있어
#    stop 시점에 자동 삭제되지만, 명시적으로 stop을 호출해서 graceful shutdown을 시도
if [ -n "$RUNNING_IDS" ]; then
    log "Stopping ${N_RUNNING} running containers..."
    echo "$RUNNING_IDS" | xargs -r docker stop 2>&1 | sed 's/^/  /' || true
fi

# 2) 매칭된 모든 컨테이너 강제 삭제 (--rm이 자동 삭제한 경우 제외하고 남은 것들)
log "Removing containers (force)..."
echo "$IDS" | xargs -r docker rm -f 2>&1 | sed 's/^/  /' || true

# 검증
REMAINING=$(docker ps -a --format "{{.ID}}" \
    | while read -r id; do
        info=$(docker ps -a --filter "id=$id" --format "{{.Names}} {{.Image}}")
        if echo "$info" | grep -qiE "$PATTERN"; then
            echo "$id"
        fi
    done)

if [ -z "$REMAINING" ]; then
    log "✅ All swebench-related containers removed."
else
    N_LEFT=$(echo "$REMAINING" | wc -l)
    log "⚠️  ${N_LEFT} container(s) still remain — manual check: docker ps -a"
fi

log "=========================================="
log "Done. preds.json / traj.json preserved — re-run './run-swebench-verified.sh' to resume."
log "=========================================="
