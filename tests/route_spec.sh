#!/usr/bin/env bash
# Specs for scripts/route.sh — candidate selection, fallthrough, failure modes.
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/spec_helper.sh"

# route_with <cache-json> <opencode-run-behaviour> [prompt] [extra env...]
# Echoes "<stdout>\n---\n<stderr>\n---\n<status>" so examples can assert on all three.
route_with() {
  local cache_json="$1" behaviour="$2" prompt="${3:-what is 2+2}"
  shift 3 2>/dev/null || shift 2
  (
    with_stub_path
    stub_bin opencode <<STUB
#!/usr/bin/env bash
# \$3 is the model id passed via -m
case "\$3:$behaviour" in
  *:all_fail)            exit 1 ;;
  */first-model:fail_first) exit 1 ;;
  */slow-model:*)        sleep 10; echo "too slow" ;;
  *)                     echo "4" ;;
esac
STUB
    printf '%s' "$cache_json" > "$STUB_BIN/cache.json"
    export OPENCODE_FREE_CACHE="$STUB_BIN/cache.json"
    # Keep the cache "fresh" so route.sh never triggers a real benchmark.
    export OPENCODE_FREE_CACHE_MAX_AGE=99999
    "$@" >/dev/null 2>&1 || true
    out=$("$PROJECT_DIR/scripts/route.sh" "$prompt" 2>"$STUB_BIN/err"); status=$?
    printf '%s\n---\n%s\n---\n%s' "$out" "$(cat "$STUB_BIN/err")" "$status"
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

describe "route.sh — fallthrough"

  context "when the top-ranked model fails"

    it "falls through to the next candidate" '
      r=$(route_with "$TWO_OK" fail_first)
      expect_contains "$(part "$r" 2)" "routed via opencode/second-model"
      expect_status "$(part "$r" 3)" "0"'

describe "route.sh — failure modes"

  context "when every candidate fails"

    it "exits 1 with ALL_FREE_MODELS_FAILED" '
      r=$(route_with "$TWO_OK" all_fail)
      expect_contains "$(part "$r" 2)" "ALL_FREE_MODELS_FAILED"
      expect_status "$(part "$r" 3)" "1"'

    it "prints nothing on stdout, so no empty answer is relayed" '
      r=$(route_with "$TWO_OK" all_fail)
      expect_eq "$(part "$r" 1)" "" "expected empty stdout"'

  context "when the cache has no working model"

    it "exits 1 with NO_FREE_MODEL_AVAILABLE" '
      r=$(route_with "$NONE_OK" ok)
      expect_contains "$(part "$r" 2)" "NO_FREE_MODEL_AVAILABLE"
      expect_status "$(part "$r" 3)" "1"'

    it "does the same for a completely empty cache" '
      r=$(route_with "$EMPTY" ok)
      expect_contains "$(part "$r" 2)" "NO_FREE_MODEL_AVAILABLE"'

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
        stub_bin opencode <<"STUB"
#!/usr/bin/env bash
echo "answered: $4"
STUB
        printf "%s" "$TWO_OK" > "$STUB_BIN/cache.json"
        export OPENCODE_FREE_CACHE="$STUB_BIN/cache.json" OPENCODE_FREE_CACHE_MAX_AGE=99999
        echo "piped prompt" | "$PROJECT_DIR/scripts/route.sh" 2>/dev/null
      )
      expect_contains "$r" "piped prompt"'

describe "route.sh — adaptive timeout"

  context "when a model measured fast in the benchmark"

    # A 1000ms canary * 6 = 6s, floored to the 20s minimum — so a model that
    # hangs must be abandoned well before the 60s hard ceiling.
    it "abandons a hanging fast model within the derived budget" '
      start=$(date +%s)
      r=$(OPENCODE_FREE_MIN_TIMEOUT=2 OPENCODE_FREE_LATENCY_MULTIPLIER=1 \
          route_with "[{\"model\":\"opencode/slow-model\",\"latency_ms\":1000,\"ok\":true}]" slow)
      elapsed=$(( $(date +%s) - start ))
      expect_status "$(part "$r" 3)" "1"
      if [ "$elapsed" -gt 8 ]; then
        _fail "expected the hanging model to be cut off quickly, took ${elapsed}s"
      fi'

    it "honours a pinned fixed timeout when adaptive is disabled" '
      start=$(date +%s)
      r=$(OPENCODE_FREE_ADAPTIVE_TIMEOUT=false OPENCODE_FREE_RUN_TIMEOUT=2 \
          route_with "[{\"model\":\"opencode/slow-model\",\"latency_ms\":1000,\"ok\":true}]" slow)
      elapsed=$(( $(date +%s) - start ))
      expect_status "$(part "$r" 3)" "1"
      if [ "$elapsed" -gt 8 ]; then
        _fail "expected the pinned 2s timeout to apply, took ${elapsed}s"
      fi'

spec_summary
