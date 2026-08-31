#!/usr/bin/env bash
# Routes one prompt to the best available free opencode model and prints its
# reply on stdout. Re-benchmarks automatically if the cache is missing/stale,
# and falls through to the next-ranked free model on failure.
#
# Usage: route.sh "<prompt text>"
#        echo "<prompt text>" | route.sh
#
# On success: reply on stdout, model name used on stderr, exit 0.
# On failure: NO_FREE_MODEL_AVAILABLE or ALL_FREE_MODELS_FAILED on stderr, exit 1.
set -uo pipefail

SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CACHE="${OPENCODE_FREE_CACHE:-$HOME/.cache/opencode-free-models.json}"
MAX_AGE_SECS="${OPENCODE_FREE_CACHE_MAX_AGE:-86400}"  # 24h
RUN_TIMEOUT_SECS="${OPENCODE_FREE_RUN_TIMEOUT:-60}"

prompt="${1:-}"
if [ -z "$prompt" ] && [ ! -t 0 ]; then
  prompt="$(cat)"
fi
if [ -z "$prompt" ]; then
  echo "usage: route.sh \"<prompt>\"  (or pipe prompt via stdin)" >&2
  exit 2
fi

need_bench=true
if [ -f "$CACHE" ]; then
  now=$(date +%s)
  mtime=$(stat -f %m "$CACHE" 2>/dev/null || stat -c %Y "$CACHE" 2>/dev/null || echo 0)
  age=$(( now - mtime ))
  if [ "$age" -lt "$MAX_AGE_SECS" ]; then
    need_bench=false
  fi
fi

if [ "$need_bench" = true ]; then
  "$SKILL_DIR/scripts/benchmark.sh" >/dev/null
fi

if [ ! -f "$CACHE" ]; then
  echo "NO_FREE_MODEL_AVAILABLE" >&2
  exit 1
fi

candidates=()
while IFS= read -r line; do
  [ -n "$line" ] && candidates+=("$line")
done < <(jq -r '.[] | select(.ok==true) | .model' "$CACHE")

if [ "${#candidates[@]}" -eq 0 ]; then
  echo "NO_FREE_MODEL_AVAILABLE" >&2
  exit 1
fi

for m in "${candidates[@]}"; do
  out=$(timeout "$RUN_TIMEOUT_SECS" opencode run -m "$m" "$prompt" 2>/dev/null)
  status=$?
  if [ $status -eq 0 ] && [ -n "$out" ]; then
    printf '%s\n' "$out"
    echo "[routed via $m]" >&2
    exit 0
  fi
done

echo "ALL_FREE_MODELS_FAILED" >&2
exit 1
