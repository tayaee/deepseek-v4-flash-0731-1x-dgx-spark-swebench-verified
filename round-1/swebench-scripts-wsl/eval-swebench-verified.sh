#!/bin/bash
set -eo pipefail

PRED_PATH="${1:-./predictions/predictions.jsonl}"
RUN_ID="${2:-exp_local_llm}"
MAX_WORKERS="${3:-4}"
DATASET="${4:-princeton-nlp/SWE-bench_Verified}"
SPLIT="${5:-test}"

PRED_DIR="$(dirname "$PRED_PATH")"
INPUT_JSON="${PRED_DIR}/preds.json"

# Only auto-convert when we have a source (preds.json) AND the destination
# (predictions.jsonl) is missing. Otherwise we'd clobber an existing jsonl.
if [ -f "$INPUT_JSON" ] && [ ! -f "$PRED_PATH" ]; then
    echo "+ Auto-converting predictions..."
    ./convert-preds-to-jsonl.sh "$INPUT_JSON" "$PRED_PATH"
fi

uv run --with swebench python -m swebench.harness.run_evaluation \
    --dataset_name "$DATASET" \
    --split "$SPLIT" \
    --predictions_path "$PRED_PATH" \
    --max_workers "$MAX_WORKERS" \
    --run_id "$RUN_ID"

python3 - "$RUN_ID" <<'PY'
import glob
import json
import os
import sys

run_id = sys.argv[1] if len(sys.argv) > 1 else "exp_local_llm"

summary_files = glob.glob(f"*.{run_id}.json") + glob.glob(f"*/*{run_id}*.json")
summary_file = None
for f in summary_files:
    if os.path.isfile(f) and not f.startswith("logs/"):
        summary_file = f
        break

submitted = 0
resolved = 0
unresolved = 0
failed = 0
total = 500
empty_patch_ids = []

if summary_file and os.path.exists(summary_file):
    with open(summary_file, "r", encoding="utf-8") as f:
        data = json.load(f)
        total = data.get("total_instances", 500)
        submitted = data.get("submitted_instances", 0)
        resolved = data.get("resolved_instances", 0)
        unresolved = data.get("unresolved_instances", 0)
        empty_patch = data.get("empty_patch_instances", 0)
        error_inst = data.get("error_instances", 0)
        failed = empty_patch + error_inst
        empty_patch_ids = data.get("empty_patch_ids", [])
        if submitted == 0:
            submitted = resolved + unresolved + failed
else:
    log_dir = os.path.join("logs", "run_evaluation", run_id)
    if os.path.exists(log_dir):
        for root, dirs, files in os.walk(log_dir):
            if "report.json" in files:
                rpt_path = os.path.join(root, "report.json")
                try:
                    with open(rpt_path, "r", encoding="utf-8") as f:
                        rdata = json.load(f)
                        for instance_id, res in rdata.items():
                            submitted += 1
                            if res.get("resolved") is True:
                                resolved += 1
                            elif res.get("resolved") is False:
                                unresolved += 1
                            else:
                                failed += 1
                                empty_patch_ids.append(instance_id)
                except Exception:
                    pass

unsubmitted = max(0, total - submitted)

# Failure breakdown with server-error slugs
server_err_slugs = {}
client_err = 0
unknown_err = 0

for iid in empty_patch_ids:
    traj_path = os.path.join("predictions", iid, f"{iid}.traj.json")
    if not os.path.exists(traj_path):
        unknown_err += 1
        continue
    try:
        with open(traj_path, "r", encoding="utf-8", errors="ignore") as tf:
            traj = json.load(tf)
        info = traj.get("info", {})
        exit_status = info.get("exit_status", "Unknown")
        messages = traj.get("messages", [])
        last_msg = messages[-1] if messages else {}
        last_content = str(last_msg.get("content", ""))

        if "cuda prefill state reset failed" in last_content:
            slug = "cuda-prefill-reset-fail"
            server_err_slugs[slug] = server_err_slugs.get(slug, 0) + 1
        elif "lazy session graph alloc failed" in last_content:
            slug = "ds4-oom"
            server_err_slugs[slug] = server_err_slugs.get(slug, 0) + 1
        elif "Server is temporarily at capacity" in last_content:
            slug = "server-capacity-rejection"
            server_err_slugs[slug] = server_err_slugs.get(slug, 0) + 1
        elif "RepeatedFormatError" in exit_status or "LimitsExceeded" in exit_status:
            client_err += 1
        else:
            unknown_err += 1
    except Exception:
        unknown_err += 1

total_server_err = sum(server_err_slugs.values())
diff = failed - (total_server_err + client_err + unknown_err)
if diff > 0:
    unknown_err += diff

pct = lambda v: int(round(v / total * 100)) if total else 0

raw_items = [
    ("", total, "Total"),
    ("├── ", submitted, "Submitted"),
    ("│   ├── ", resolved, "Resolved"),
    ("│   ├── ", unresolved, "Unresolved"),
    ("│   └── ", failed, "Failed"),
    ("│       ├── ", total_server_err, "server-error"),
]

slug_items = sorted(server_err_slugs.items(), key=lambda x: x[1], reverse=True)
for idx, (slug, cnt) in enumerate(slug_items):
    sub_prefix = "│       │   └── " if idx == len(slug_items) - 1 else "│       │   ├── "
    raw_items.append((sub_prefix, cnt, slug))

raw_items.extend([
    ("│       ├── ", client_err, "client-error"),
    ("│       └── ", unknown_err, "unknown"),
    ("└── ", unsubmitted, "Unsubmitted"),
])

import unicodedata

def wcswidth(s):
    return sum(2 if unicodedata.east_asian_width(c) in ('F', 'W') else 1 for c in s)

def pad(s, width):
    w = wcswidth(s)
    return s + ' ' * max(0, width - w)

formatted_items = []
for pfx, cnt, lbl in raw_items:
    p = pct(cnt)
    left_str = f"{pfx}{cnt} ({p:>3}%)"
    formatted_items.append((left_str, lbl))

max_left_w = max(wcswidth(left_str) for left_str, _ in formatted_items)

title = "SWE-bench Verified over DeepSeek-V4-Flash-0731 on Single DGX Spark"
border = "=" * len(title)

print("")
print(border)
print(title)
print(border)
for left_str, lbl in formatted_items:
    print(f"{pad(left_str, max_left_w + 4)}{lbl}")
print(border)
PY
