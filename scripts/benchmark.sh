#!/usr/bin/env bash
# Discovers opencode's free models, benchmarks all of them in parallel with one
# canary prompt, ranks them (working models first, then by latency), and
# caches the ranking to disk.
#
# Usage: benchmark.sh
# Output: JSON array on stdout, e.g.
#   [{"model":"opencode/mimo-v2.5-free","latency_ms":1830,"ok":true}, ...]
set -uo pipefail

CANARY="Reply with exactly: pong"
CACHE="${OPENCODE_FREE_CACHE:-$HOME/.cache/opencode-free-models.json}"
TIMEOUT_SECS="${OPENCODE_FREE_BENCH_TIMEOUT:-30}"
# Only ever treat models from opencode's own hosted tiers as "free". A model's
# reported cost can be 0 due to a metadata gap rather than an actual price, so
# we don't trust cost==0 alone on bring-your-own-key providers (openai,
# anthropic, ...) -- a false positive there would silently bill the user's own
# account instead of using opencode's free tier.
FREE_PROVIDERS="${OPENCODE_FREE_PROVIDERS:-opencode opencode-go}"

if ! command -v opencode >/dev/null 2>&1; then
  echo '{"error":"opencode CLI not found on PATH"}' >&2
  exit 1
fi
if ! command -v jq >/dev/null 2>&1; then
  echo '{"error":"jq not found on PATH"}' >&2
  exit 1
fi

TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

# Discover free models from real cost metadata (`opencode models --verbose`),
# not from a "free" substring in the model name -- some genuinely free models
# don't have "free" in their id (e.g. opencode/big-pickle), and name-matching
# would silently miss them. --verbose prints "provider/model" header lines
# followed by a pretty-printed JSON block per model; the awk pass re-joins
# each block onto one line (tracking brace depth) so jq can read it.
discover_free_models() {
  opencode models --verbose 2>/dev/null | awk '
    BEGIN { buf=""; depth=0; header="" }
    /^[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+$/ && depth==0 {
      if (header != "") printf "%s\t%s\n", header, buf
      header=$0; buf=""; next
    }
    {
      line=$0
      buf = buf line
      o = gsub(/{/,"{",line)
      c = gsub(/}/,"}",line)
      depth += o - c
    }
    END { if (header != "") printf "%s\t%s\n", header, buf }
  ' | while IFS=$'\t' read -r header json; do
      provider="${header%%/*}"
      case " $FREE_PROVIDERS " in
        *" $provider "*) ;;
        *) continue ;;
      esac
      # Skip entries whose JSON block didn't survive the line-rejoin (e.g. a
      # description containing a literal newline) rather than error out.
      is_free=$(printf '%s' "$json" | jq -r '((.cost.input // 1) == 0) and ((.cost.output // 1) == 0)' 2>/dev/null) || continue
      [ "$is_free" = "true" ] && echo "$header"
    done
}

models=()
while IFS= read -r line; do
  [ -n "$line" ] && models+=("$line")
done < <(discover_free_models)

if [ "${#models[@]}" -eq 0 ]; then
  echo "[]"
  exit 0
fi

bench_one() {
  local model="$1" outfile="$2"
  local start end ms out status ok
  start=$(date +%s%N)
  out=$(timeout "$TIMEOUT_SECS" opencode run -m "$model" "$CANARY" 2>&1)
  status=$?
  end=$(date +%s%N)
  ms=$(( (end - start) / 1000000 ))
  if [ $status -eq 0 ] && printf '%s' "$out" | grep -qi "pong"; then
    ok=true
  else
    ok=false
  fi
  jq -cn --arg m "$model" --argjson ms "$ms" --argjson ok "$ok" \
    '{model:$m, latency_ms:$ms, ok:$ok}' > "$outfile"
}

i=0
for m in "${models[@]}"; do
  bench_one "$m" "$TMPDIR/$i.json" &
  i=$((i+1))
done
wait

mkdir -p "$(dirname "$CACHE")"
jq -s 'sort_by(.ok == false, .latency_ms)' "$TMPDIR"/*.json | tee "$CACHE"
