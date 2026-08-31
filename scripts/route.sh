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

# shellcheck source=lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CACHE="${OPENCODE_FREE_CACHE:-$HOME/.cache/opencode-free-models.json}"
MAX_AGE_SECS="${OPENCODE_FREE_CACHE_MAX_AGE:-86400}"  # 24h
# Hard ceiling per model. By default the real per-model budget is derived from
# that model's measured benchmark latency (see below) so a model that pinged in
# 4s doesn't hold the user for a full minute before we fall through to the next
# one; set OPENCODE_FREE_RUN_TIMEOUT to pin every model to a fixed value.
RUN_TIMEOUT_SECS="${OPENCODE_FREE_RUN_TIMEOUT:-60}"
ADAPTIVE_TIMEOUT="${OPENCODE_FREE_ADAPTIVE_TIMEOUT:-true}"
# A real prompt does more work than the one-word canary, so scale the measured
# latency up generously before using it as a deadline.
LATENCY_MULTIPLIER="${OPENCODE_FREE_LATENCY_MULTIPLIER:-6}"
MIN_TIMEOUT_SECS="${OPENCODE_FREE_MIN_TIMEOUT:-20}"

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

# Carry each candidate's measured canary latency along with its name, so the
# per-model deadline can be derived from it. Tab-separated: "<model>\t<ms>".
candidates=()
while IFS= read -r line; do
  [ -n "$line" ] && candidates+=("$line")
done < <(jq -r '.[] | select(.ok==true) | "\(.model)\t\(.latency_ms)"' "$CACHE")

if [ "${#candidates[@]}" -eq 0 ]; then
  echo "NO_FREE_MODEL_AVAILABLE" >&2
  exit 1
fi

for entry in "${candidates[@]}"; do
  m="${entry%%$'\t'*}"
  latency_ms="${entry##*$'\t'}"

  budget="$RUN_TIMEOUT_SECS"
  if [ "$ADAPTIVE_TIMEOUT" = "true" ] && [ "$latency_ms" -gt 0 ] 2>/dev/null; then
    scaled=$(( (latency_ms * LATENCY_MULTIPLIER + 999) / 1000 ))
    [ "$scaled" -lt "$MIN_TIMEOUT_SECS" ] && scaled="$MIN_TIMEOUT_SECS"
    [ "$scaled" -gt "$RUN_TIMEOUT_SECS" ] && scaled="$RUN_TIMEOUT_SECS"
    budget="$scaled"
  fi

  out=$(run_with_timeout "$budget" opencode run -m "$m" "$prompt" 2>/dev/null)
  status=$?
  if [ $status -eq 0 ] && [ -n "$out" ]; then
    printf '%s\n' "$out"
    echo "[routed via $m]" >&2
    exit 0
  fi
done

echo "ALL_FREE_MODELS_FAILED" >&2
exit 1
