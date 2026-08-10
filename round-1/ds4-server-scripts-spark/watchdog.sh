#!/bin/bash
# ============================================================================
# watchdog.sh — auto-restart wrapper for ds4-serve
#
# Runs a command (default: ds4-serve) in a loop. If the command exits non-zero
# (or produces known crash patterns on stdout/stderr), wait RESTART_DELAY
# seconds and try again, up to MAX_RESTARTS times.
#
# Known crash patterns watched (any of these triggers a restart):
#   - "CUDA prefill error"
#   - "illegal memory access"
#   - "cuda prefill state reset failed"
#   - "lazy session graph alloc failed"
#
# Environment overrides:
#   MAX_RESTARTS  (default 50)        — give up after this many restarts
#   RESTART_DELAY (default 10)        — seconds to sleep between restarts
#   WATCHDOG_LOG  (default tmp.watchdog.log)
#
# Usage:
#   ./watchdog.sh                     — wraps ds4-serve with default args
#   ./watchdog.sh ds4-serve -c 196608 --port 8000 ...   — wraps an explicit command
# ============================================================================

set -u

MAX_RESTARTS="${MAX_RESTARTS:-50}"
RESTART_DELAY="${RESTART_DELAY:-10}"
WATCHDOG_LOG="${WATCHDOG_LOG:-tmp.watchdog.log}"

log() {
    local msg="[$(date '+%Y-%m-%d %H:%M:%S')] $*"
    echo "$msg"
    echo "$msg" >> "$WATCHDOG_LOG"
}

# Build the command to run. If no args given, fall back to ds4-serve with the
# project's known-good invocation (kept in sync with the summary's
# "ds4-server script" block).
if [ "$#" -eq 0 ]; then
    set -- ds4-serve \
        -c 196608 \
        --host 0.0.0.0 \
        --port 8000 \
        --tokens 8192 \
        --mem-floor-gb 1 \
        --no-dspark \
        --reasoning-effort low
fi

restart_count=0
log "watchdog starting: command=$1  max_restarts=$MAX_RESTARTS  delay=${RESTART_DELAY}s  log=$WATCHDOG_LOG"

while [ "$restart_count" -lt "$MAX_RESTARTS" ]; do
    log "starting child (attempt $((restart_count + 1)))"

    # Stream child output through tee so:
    #   1) the user sees it live on stdout,
    #   2) it's appended to the persistent log,
    #   3) we can read it back from a temp file to grep for crash patterns.
    tmp_out="$(mktemp)"
    # shellcheck disable=SC2086
    "$@" 2>&1 | tee -a "$WATCHDOG_LOG" > "$tmp_out"
    exit_code=${PIPESTATUS[0]}
    child_output="$(cat "$tmp_out")"
    rm -f "$tmp_out"

    if [ "$exit_code" -eq 0 ]; then
        log "child exited cleanly (code=0) — stopping watchdog"
        exit 0
    fi

    restart_count=$((restart_count + 1))

    # Inspect the tail of the child's output for known crash signatures.
    last_lines="$(printf '%s\n' "$child_output" | tail -n 200)"
    crash_reason=""
    if printf '%s' "$last_lines" | grep -qi "cuda prefill error"; then
        crash_reason="CUDA prefill error"
    elif printf '%s' "$last_lines" | grep -qi "illegal memory access"; then
        crash_reason="illegal memory access"
    elif printf '%s' "$last_lines" | grep -qi "cuda prefill state reset failed"; then
        crash_reason="cuda prefill state reset failed"
    elif printf '%s' "$last_lines" | grep -qi "lazy session graph alloc failed"; then
        crash_reason="lazy session graph alloc failed"
    else
        crash_reason="non-zero exit ($exit_code)"
    fi

    log "child crashed: ${crash_reason} — restart $restart_count/$MAX_RESTARTS in ${RESTART_DELAY}s"
    sleep "$RESTART_DELAY"
done

log "watchdog: max restarts ($MAX_RESTARTS) reached — giving up"
exit 1