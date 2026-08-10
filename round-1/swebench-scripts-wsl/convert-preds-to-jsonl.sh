#!/bin/bash
set -eo pipefail

INPUT_FILE="${1:-./predictions/preds.json}"
OUTPUT_FILE="${2:-./predictions/predictions.jsonl}"

if [ ! -f "$INPUT_FILE" ]; then
    echo "ERROR: $INPUT_FILE not found — mini-swe-agent produced no output" >&2
    exit 1
fi

if [ ! -s "$INPUT_FILE" ]; then
    echo "ERROR: $INPUT_FILE is empty — no predictions to evaluate" >&2
    exit 1
fi

python3 - "$INPUT_FILE" "$OUTPUT_FILE" <<'PY'
import json
import sys

input_path = sys.argv[1]
output_path = sys.argv[2]

with open(input_path) as f:
    preds = json.load(f)

if not preds:
    print("No predictions to convert (empty dict)", file=sys.stderr)
    sys.exit(1)

with open(output_path, "w") as f:
    for iid, p in preds.items():
        f.write(json.dumps(p) + "\n")

print(f"Wrote {len(preds)} predictions to {output_path}")
PY
