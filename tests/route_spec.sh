#!/usr/bin/env bash
# Specs for scripts/route.sh — candidate selection, success detection,
# fallthrough, demotion, and the usage log.
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/spec_helper.sh"

# route_with <cache-json> <behaviour> [prompt] [VAR=VALUE ...]
# Echoes "<stdout>\n---\n<stderr>\n---\n<status>\n---\n<final cache>\n---\n<usage log>"
# so examples can assert on every observable effect of one route.
route_with() {
  local cache_json="$1" behaviour="$2" prompt="${3:-what is 2+2}"
  shift 3 2>/dev/null || shift 2
  (
    with_stub_path
    stub_opencode
    export RUN_BEHAVIOUR="$behaviour"
    printf '%s' "$cache_json" > "$STUB_BIN/cache.json"
    export OPENCODE_FREE_CACHE="$STUB_BIN/cache.json"
    # Keep the cache "fresh" so route.sh never triggers a real benchmark.
    export OPENCODE_FREE_CACHE_MAX_AGE=99999
    export FREELOADER_USAGE_LOG="$STUB_BIN/usage.jsonl"
    for kv in "$@"; do export "${kv?}"; done
    out=$("$PROJECT_DIR/scripts/route.sh" "$prompt" 2>"$STUB_BIN/err"); status=$?
    printf '%s\n---\n%s\n---\n%s\n---\n%s\n---\n%s' \
      "$out" "$(cat "$STUB_BIN/err")" "$status" \
      "$(cat "$STUB_BIN/cache.json")" "$(cat "$STUB_BIN/usage.jsonl" 2>/dev/null)"
  )
}

part() { printf '%s' "$1" | awk -v n="$2" 'BEGIN{RS="\n---\n"} NR==n'; }

TWO_OK='[{"model":"opencode/first-model","latency_ms":1000,"ok":true},
         {"model":"opencode/second-model","latency_ms":2000,"ok":true}]'
NONE_OK='[{"model":"opencode/broken","latency_ms":30000,"ok":false}]'
EMPTY='[]'

describe "route.sh — happy path"

  context "with a fresh ranked cache"

    it "routes to the top-ranked model and prints its reply" '
      r=$(route_with "$TWO_OK" ok)
      expect_contains "$(part "$r" 1)" "4"
      expect_status "$(part "$r" 3)" "0"'

    it "names the model that answered, on stderr" '
      r=$(route_with "$TWO_OK" ok)
      expect_contains "$(part "$r" 2)" "routed via opencode/first-model"'

    it "keeps the reply itself clean of the routing note" '
      r=$(route_with "$TWO_OK" ok)
      expect_not_contains "$(part "$r" 1)" "routed via"'

    it "does not leak the raw JSON event stream into the reply" '
      r=$(route_with "$TWO_OK" ok)
      expect_not_contains "$(part "$r" 1)" "step_finish"
      expect_not_contains "$(part "$r" 1)" "\"type\""'

describe "route.sh — success detection"

  # `opencode run` exits 0 even when the stream is nothing but an error event.
  # Treating a non-empty stdout as an answer would relay that failure to the
  # user as though a model had answered it.
  context "when a model exits 0 but emits only an error event"

    it "does not relay it as an answer" '
      r=$(route_with "[{\"model\":\"opencode/only\",\"latency_ms\":1000,\"ok\":true}]" error_stream)
      expect_status "$(part "$r" 3)" "1"
      expect_contains "$(part "$r" 2)" "ALL_FREE_MODELS_FAILED"'

    it "prints nothing on stdout" '
      r=$(route_with "[{\"model\":\"opencode/only\",\"latency_ms\":1000,\"ok\":true}]" error_stream)
      expect_eq "$(part "$r" 1)" "" "expected empty stdout"'

  context "when the stream is cut off before step_finish"

    it "refuses the truncated answer instead of relaying half a reply" '
      r=$(route_with "[{\"model\":\"opencode/only\",\"latency_ms\":1000,\"ok\":true}]" no_finish)
      expect_status "$(part "$r" 3)" "1"
      expect_eq "$(part "$r" 1)" "" "expected empty stdout"'

  context "when the run completes with no text at all"

    it "treats an empty reply as a failure" '
      r=$(route_with "[{\"model\":\"opencode/only\",\"latency_ms\":1000,\"ok\":true}]" empty_reply)
      expect_status "$(part "$r" 3)" "1"'

  context "when opencode falls back to the tool-enabled default agent"

    # The sandbox is the entire basis for "we never route private data".
    # A right-looking answer from an unsandboxed agent must still be refused.
    it "refuses the reply even though the model answered correctly" '
      r=$(route_with "[{\"model\":\"opencode/only\",\"latency_ms\":1000,\"ok\":true}]" agent_fallback)
      expect_status "$(part "$r" 3)" "1"
      expect_eq "$(part "$r" 1)" "" "expected the unsandboxed answer to be dropped"'

    it "reports it as a sandbox failure, not as the models failing" '
      r=$(route_with "$TWO_OK" agent_fallback)
      expect_contains "$(part "$r" 2)" "FREELOADER_SANDBOX_UNAVAILABLE"
      expect_not_contains "$(part "$r" 2)" "ALL_FREE_MODELS_FAILED"'

    # A broken sandbox is our fault, not the models'"'"'. Demoting them would
    # poison a good ranking and force a needless re-benchmark.
    it "does not demote any model for our own config failure" '
      r=$(route_with "$TWO_OK" agent_fallback)
      ok=$(printf "%s" "$(part "$r" 4)" | jq "[.[] | select(.ok)] | length")
      expect_eq "$ok" "2" "expected the ranking to survive a sandbox failure"'

    it "stops immediately instead of trying every model in turn" '
      r=$(route_with "$TWO_OK" agent_fallback)
      n=$(printf "%s" "$(part "$r" 2)" | grep -c "FREELOADER_SANDBOX_UNAVAILABLE" || true)
      expect_eq "$n" "1"'

describe "route.sh — fallthrough and demotion"

  context "when the top-ranked model fails"

    it "falls through to the next candidate" '
      r=$(route_with "$TWO_OK" fail_first "what is 2+2" FAIL_MODEL=opencode/first-model)
      expect_contains "$(part "$r" 2)" "routed via opencode/second-model"
      expect_status "$(part "$r" 3)" "0"'

    # Without this, a model that benchmarks ok but fails on real prompts stays
    # at rank 1 and burns its full timeout on every prompt for 24h.
    it "demotes the failed model in the cache" '
      r=$(route_with "$TWO_OK" fail_first "what is 2+2" FAIL_MODEL=opencode/first-model)
      ok=$(printf "%s" "$(part "$r" 4)" | jq -r ".[] | select(.model==\"opencode/first-model\") | .ok")
      expect_eq "$ok" "false" "expected the failed model to be demoted"'

    it "records why it was demoted" '
      r=$(route_with "$TWO_OK" fail_first "what is 2+2" FAIL_MODEL=opencode/first-model)
      reason=$(printf "%s" "$(part "$r" 4)" | jq -r ".[] | select(.model==\"opencode/first-model\") | .demote_reason // \"\"")
      if [ -z "$reason" ]; then _fail "expected a demote_reason to be recorded"; fi'

    it "leaves the model that answered untouched" '
      r=$(route_with "$TWO_OK" fail_first "what is 2+2" FAIL_MODEL=opencode/first-model)
      ok=$(printf "%s" "$(part "$r" 4)" | jq -r ".[] | select(.model==\"opencode/second-model\") | .ok")
      expect_eq "$ok" "true"'

    it "keeps the cache valid JSON after rewriting it" '
      r=$(route_with "$TWO_OK" fail_first "what is 2+2" FAIL_MODEL=opencode/first-model)
      printf "%s" "$(part "$r" 4)" | jq -e . >/dev/null 2>&1 || _fail "cache is not valid JSON"'

describe "route.sh — usage log"

  context "after a successful route"

    it "appends one record naming the model that answered" '
      r=$(route_with "$TWO_OK" ok)
      m=$(printf "%s" "$(part "$r" 5)" | jq -r ".model")
      expect_eq "$m" "opencode/first-model"'

    it "records a non-zero dollar estimate of what was saved" '
      r=$(route_with "$TWO_OK" ok)
      usd=$(printf "%s" "$(part "$r" 5)" | jq -r ".saved.usd > 0")
      expect_eq "$usd" "true"'

    it "records the free tokens actually spent" '
      r=$(route_with "$TWO_OK" ok)
      t=$(printf "%s" "$(part "$r" 5)" | jq -r ".free_tokens.total")
      expect_eq "$t" "120"'

    it "attributes the saving to the configured baseline model" '
      r=$(route_with "$TWO_OK" ok "what is 2+2" FREELOADER_PRICE_MODEL=claude-opus-5 FREELOADER_PRICE_IN=5 FREELOADER_PRICE_OUT=25)
      b=$(printf "%s" "$(part "$r" 5)" | jq -r ".saved.baseline_model")
      expect_eq "$b" "claude-opus-5"'

  context "after every model fails"

    it "logs the failure rather than silently dropping it" '
      r=$(route_with "$TWO_OK" all_fail)
      ok=$(printf "%s" "$(part "$r" 5)" | jq -r ".ok")
      expect_eq "$ok" "false"'

describe "route.sh — failure modes"

  context "when every candidate fails"

    it "exits 1 with ALL_FREE_MODELS_FAILED" '
      r=$(route_with "$TWO_OK" all_fail)
      expect_contains "$(part "$r" 2)" "ALL_FREE_MODELS_FAILED"
      expect_status "$(part "$r" 3)" "1"'

    it "prints nothing on stdout, so no empty answer is relayed" '
      r=$(route_with "$TWO_OK" all_fail)
      expect_eq "$(part "$r" 1)" "" "expected empty stdout"'

  # Every candidate can get demoted within one 24h cache window. The cache is
  # then "fresh" by mtime but empty of usable models — which is a stale ranking,
  # not an absence of free models. Re-benchmark once before giving up.
  context "when the cache has no working model left"

    it "re-benchmarks once instead of reporting no free models" '
      r=$(route_with "$NONE_OK" ok)
      expect_status "$(part "$r" 3)" "0"
      expect_contains "$(part "$r" 2)" "routed via"'

    it "does the same for a completely empty cache" '
      r=$(route_with "$EMPTY" ok)
      expect_status "$(part "$r" 3)" "0"'

    it "refreshes the cache on disk while doing so" '
      r=$(route_with "$NONE_OK" ok)
      n=$(printf "%s" "$(part "$r" 4)" | jq "[.[] | select(.ok)] | length")
      expect_gt "$n" "0"'

  context "when re-benchmarking also turns up nothing"

    it "exits 1 with NO_FREE_MODEL_AVAILABLE" '
      r=$(route_with "$NONE_OK" ok "what is 2+2" MODELS_EMPTY=1)
      expect_contains "$(part "$r" 2)" "NO_FREE_MODEL_AVAILABLE"
      expect_status "$(part "$r" 3)" "1"'

    it "prints nothing on stdout" '
      r=$(route_with "$EMPTY" ok "what is 2+2" MODELS_EMPTY=1)
      expect_eq "$(part "$r" 1)" "" "expected empty stdout"'

describe "route.sh — input handling"

  context "with no prompt at all"

    it "exits 2 and explains usage" '
      out=$("$PROJECT_DIR/scripts/route.sh" </dev/null 2>&1); status=$?
      expect_status "$status" "2"
      expect_contains "$out" "usage:"'

  context "with the prompt piped on stdin"

    it "reads the prompt from stdin" '
      r=$(
        with_stub_path
        stub_opencode
        export RUN_BEHAVIOUR=echo
        printf "%s" "$TWO_OK" > "$STUB_BIN/cache.json"
        export OPENCODE_FREE_CACHE="$STUB_BIN/cache.json" OPENCODE_FREE_CACHE_MAX_AGE=99999
        export FREELOADER_USAGE_LOG="$STUB_BIN/usage.jsonl"
        echo "piped prompt" | "$PROJECT_DIR/scripts/route.sh" 2>/dev/null
      )
      expect_contains "$r" "piped prompt"'

describe "route.sh — adaptive timeout"

  context "when a model measured fast in the benchmark"

    # A 1000ms canary * 6 = 6s, floored to the 20s minimum — so a model that
    # hangs must be abandoned well before the 60s hard ceiling.
    it "abandons a hanging fast model within the derived budget" '
      start=$(date +%s)
      r=$(route_with "[{\"model\":\"opencode/slow-model\",\"latency_ms\":1000,\"ok\":true}]" slow \
          "what is 2+2" OPENCODE_FREE_MIN_TIMEOUT=2 OPENCODE_FREE_LATENCY_MULTIPLIER=1)
      elapsed=$(( $(date +%s) - start ))
      expect_status "$(part "$r" 3)" "1"
      if [ "$elapsed" -gt 8 ]; then
        _fail "expected the hanging model to be cut off quickly, took ${elapsed}s"
      fi'

    it "honours a pinned fixed timeout when adaptive is disabled" '
      start=$(date +%s)
      r=$(route_with "[{\"model\":\"opencode/slow-model\",\"latency_ms\":1000,\"ok\":true}]" slow \
          "what is 2+2" OPENCODE_FREE_ADAPTIVE_TIMEOUT=false OPENCODE_FREE_RUN_TIMEOUT=2)
      elapsed=$(( $(date +%s) - start ))
      expect_status "$(part "$r" 3)" "1"
      if [ "$elapsed" -gt 8 ]; then
        _fail "expected the pinned 2s timeout to apply, took ${elapsed}s"
      fi'

spec_summary
