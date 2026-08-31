#!/usr/bin/env bash
# Discovers opencode's free models, probes all of them in parallel, ranks them
# (most capable first, then fastest), and caches the ranking to disk.
#
# Usage: benchmark.sh
# Output: JSON array on stdout, e.g.
#   [{"model":"opencode/mimo-v2.5-free","latency_ms":1830,"ok":true,"score":2}, ...]
set -uo pipefail

# shellcheck source=lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

# Two probes, not one. A liveness ping alone ranks a fast model that cannot
# follow an instruction above a slower one that can — and "follow a short
# instruction exactly" is the entire job we route to these models. The second
# probe needs a correct answer AND obedience to a format constraint, which is
# what separates a usable free model from one that merely responds.
PROBE_1_PROMPT="Reply with exactly: pong"
PROBE_1_EXPECT="pong"
PROBE_2_PROMPT="What is 17 multiplied by 23? Reply with only the number, no words."
PROBE_2_EXPECT="391"

CACHE="${OPENCODE_FREE_CACHE:-$HOME/.cache/opencode-free-models.json}"
TIMEOUT_SECS="${OPENCODE_FREE_BENCH_TIMEOUT:-30}"
# Free tiers are rate-limited. Firing every discovered model at once can trip
# those limits and mark a perfectly good model as broken, so probe in batches.
CONCURRENCY="${OPENCODE_FREE_BENCH_CONCURRENCY:-4}"
# When true, a model must pass BOTH probes to be routable. If that leaves
# nothing usable we relax to liveness-only rather than stranding the skill.
STRICT="${OPENCODE_FREE_STRICT:-true}"
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

WORKDIR=$(mktemp -d)
trap 'rm -rf "$WORKDIR"' EXIT

# Discover free models from real cost metadata (`opencode models --verbose`),
# not from a "free" substring in the model name -- some genuinely free models
# don't have "free" in their id (e.g. opencode/big-pickle), and name-matching
# would silently miss them.
#
# --verbose prints a "provider/model" header line followed by a pretty-printed
# JSON block per model. Rather than parse that mixed stream, drop the header
# lines entirely and let jq consume the remaining concatenated JSON objects
# natively -- each block already carries `providerID` and `id`, so the header
# is redundant. (An earlier version brace-counted the blocks back onto single
# lines in awk; that desynchronised and silently dropped
# opencode/muse-spark-1.2-contributor-free, one of the *fastest* free models.)
discover_free_models() {
  opencode models --verbose 2>/dev/null \
    | grep -v -E '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$' \
    | jq -r --arg providers "$FREE_PROVIDERS" '
        ($providers | split(" ")) as $allowed
        | select((.cost.input // 1) == 0 and (.cost.output // 1) == 0)
        | select(.providerID as $p | $allowed | index($p))
        | "\(.providerID)/\(.id)"
      ' 2>/dev/null
}

models=()
while IFS= read -r line; do
  [ -n "$line" ] && models+=("$line")
done < <(discover_free_models)

if [ "${#models[@]}" -eq 0 ]; then
  echo "[]"
  exit 0
fi

# probe <model> <prompt> <expected-substring>
# Echoes "<passed:true|false> <elapsed_ms>".
probe() {
  local model="$1" prompt="$2" expect="$3"
  local start end ms stream status passed=false

  start=$(date +%s%N)
  stream=$(oc_run "$TIMEOUT_SECS" "$model" "$prompt")
  status=$?
  end=$(date +%s%N)
  ms=$(( (end - start) / 1000000 ))

  # Same success contract as route.sh: exit 0 means nothing on its own, because
  # opencode exits 0 on a pure-error stream.
  if [ $status -ne 124 ] \
     && [ -z "$(oc_error "$stream")" ] \
     && [ "$(oc_finished "$stream")" = "true" ] \
     && printf '%s' "$(oc_text "$stream")" | grep -qiF "$expect"; then
    passed=true
  fi
  printf '%s %s' "$passed" "$ms"
}

bench_one() {
  local model="$1" outfile="$2"
  local r1 r2 alive_ok alive_ms exact_ok exact_ms score latency

  r1=$(probe "$model" "$PROBE_1_PROMPT" "$PROBE_1_EXPECT")
  alive_ok="${r1%% *}"; alive_ms="${r1##* }"

  # No point spending the second probe on a model that isn't answering at all.
  if [ "$alive_ok" = "true" ]; then
    r2=$(probe "$model" "$PROBE_2_PROMPT" "$PROBE_2_EXPECT")
    exact_ok="${r2%% *}"; exact_ms="${r2##* }"
  else
    exact_ok=false; exact_ms=0
  fi

  score=0
  [ "$alive_ok" = "true" ] && score=$((score + 1))
  [ "$exact_ok" = "true" ] && score=$((score + 1))

  # The slower of the two probes, so the deadline route.sh derives from this
  # isn't set by a model's best-case round trip.
  latency="$alive_ms"
  [ "$exact_ms" -gt "$latency" ] 2>/dev/null && latency="$exact_ms"

  jq -cn --arg m "$model" --argjson ms "$latency" --argjson score "$score" \
    --argjson alive "$alive_ok" --argjson exact "$exact_ok" \
    '{model:$m, latency_ms:$ms, score:$score,
      probes:{responds:$alive, follows_instruction:$exact}}' > "$outfile"
}

# Batched fan-out. bash 3.2 (still the system bash on macOS) has no `wait -n`,
# so we run a full batch and wait for it rather than refilling one slot at a time.
i=0
running=0
for m in "${models[@]}"; do
  bench_one "$m" "$WORKDIR/$i.json" &
  i=$((i + 1))
  running=$((running + 1))
  if [ "$running" -ge "$CONCURRENCY" ]; then
    wait
    running=0
  fi
done
wait

# Rank: capability first, then speed. `ok` is what route.sh actually reads.
ranked=$(jq -s --argjson strict "$([ "$STRICT" = "true" ] && echo true || echo false)" '
  ( map(.score == 2) | any ) as $any_perfect
  # Only hold the strict bar if at least one model can clear it; otherwise fall
  # back to liveness so a bad day for every free model doesn'"'"'t disable the skill.
  | (if $strict and $any_perfect then 2 else 1 end) as $bar
  | map(.ok = (.score >= $bar))
  | sort_by([(if .ok then 0 else 1 end), (-.score), .latency_ms])' "$WORKDIR"/*.json)

mkdir -p "$(dirname "$CACHE")"
printf '%s\n' "$ranked" | tee "$CACHE"
