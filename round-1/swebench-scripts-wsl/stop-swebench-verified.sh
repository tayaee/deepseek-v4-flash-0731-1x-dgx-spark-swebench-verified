#!/bin/bash
# stop-swebench-verified.sh
#   - Stops and removes all running mini-swe-agent / swebench harness containers.
#   - Keeps images (the swebench image is several GB; no need to re-pull).
#   - Leaves preds.json / traj.json untouched, so the next run can resume
#     incrementally.
#
# ⚠️  Incremental-resume caveat (mini-swe-agent):
#   - Instances already in preds.json: skipped on the next run
#     (skipped by main()'s `existing_instances` check).
#   - In-flight instances (container started but LLM still responding or
#     executing): NOT in preds.json, so they get re-run from scratch. This
#     happens because process_instance() calls remove_from_preds_file() +
#     traj.json unlink() on entry.
#   - Only instances that have made it into preds.json are guaranteed to
#     resume incrementally.

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

# Pre-flight checks
if ! command -v docker >/dev/null 2>&1; then
    log "ERROR: docker command not found"
    exit 1
fi
if ! docker info >/dev/null 2>&1; then
    log "ERROR: docker daemon not reachable"
    exit 1
fi

# Find matching containers (running + stopped)
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

# 1) Stop running containers. mini-swe-agent containers are launched with
#    `--rm`, so they'd auto-delete on stop, but we explicitly call `docker
#    stop` to attempt a graceful shutdown first.
if [ -n "$RUNNING_IDS" ]; then
    log "Stopping ${N_RUNNING} running containers..."
    echo "$RUNNING_IDS" | xargs -r docker stop 2>&1 | sed 's/^/  /' || true
fi

# 2) Force-remove all matched containers (covers those not already auto-removed
#    by --rm above).
log "Removing containers (force)..."
echo "$IDS" | xargs -r docker rm -f 2>&1 | sed 's/^/  /' || true

# Verify
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
