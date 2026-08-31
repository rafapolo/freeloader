#!/usr/bin/env bash
# Specs for scripts/benchmark.sh — free-model discovery and ranking.
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/spec_helper.sh"

# Runs benchmark.sh against a stubbed `opencode`, with a scratch cache.
# $1 = behaviour for `opencode run`: "ok" (default) or "all_fail".
run_benchmark() {
  (
    with_stub_path
    stub_bin opencode <<STUB
#!/usr/bin/env bash
case "\$1" in
  models) cat "$FIXTURES/models_verbose.txt" ;;
  run)
    [ "\${RUN_BEHAVIOUR:-ok}" = "all_fail" ] && exit 1
    case "\$3" in
      */brace-in-string) sleep 0.3 ;;
      */go-free)         sleep 0.2 ;;
      */big-pickle)      sleep 0.1 ;;
    esac
    echo "pong"
    ;;
esac
STUB
    export RUN_BEHAVIOUR="${1:-ok}"
    export OPENCODE_FREE_CACHE="$STUB_BIN/cache.json"
    "$PROJECT_DIR/scripts/benchmark.sh" 2>/dev/null
  )
}

OUT_OK="$(run_benchmark)"
OUT_FAIL="$(run_benchmark all_fail)"

describe "benchmark.sh — discovery"

  context "given opencode's --verbose catalogue"

    it "finds free models on opencode's own hosted tier" '
      expect_contains "$OUT_OK" "opencode/free-classic"'

    it "finds free models on the opencode-go tier" '
      expect_contains "$OUT_OK" "opencode-go/go-free"'

    it "finds a free model whose id has no \"free\" substring" '
      expect_contains "$OUT_OK" "opencode/big-pickle"'

    it "keeps an entry whose JSON strings contain braces (regression)" '
      expect_contains "$OUT_OK" "opencode/brace-in-string"'

  context "cost and provider guards"

    it "excludes a model charging for input and output" '
      expect_not_contains "$OUT_OK" "opencode/paid-model"'

    it "excludes a model free on input but charging output" '
      expect_not_contains "$OUT_OK" "opencode/output-only-cost"'

    it "excludes a cost-0 bring-your-own-key provider (would bill the user)" '
      expect_not_contains "$OUT_OK" "openai/gpt-zero-cost"'

    it "emits exactly the four free models from the fixture" '
      n=$(printf "%s" "$OUT_OK" | jq "length")
      expect_eq "$n" "4"'

describe "benchmark.sh — ranking"

  context "when every candidate answers the canary"

    it "marks them ok" '
      n=$(printf "%s" "$OUT_OK" | jq "[.[] | select(.ok)] | length")
      expect_eq "$n" "4"'

    it "sorts by ascending latency" '
      sorted=$(printf "%s" "$OUT_OK" | jq -r "[.[].latency_ms] | . == sort")
      expect_eq "$sorted" "true" "expected latencies sorted ascending"'

    it "records a positive latency for each model" '
      n=$(printf "%s" "$OUT_OK" | jq "[.[] | select(.latency_ms > 0)] | length")
      expect_eq "$n" "4"'

  context "when the canary fails for every model"

    it "marks them all not-ok rather than dropping them" '
      total=$(printf "%s" "$OUT_FAIL" | jq "length")
      ok=$(printf "%s" "$OUT_FAIL" | jq "[.[] | select(.ok)] | length")
      expect_eq "$total" "4"
      expect_eq "$ok" "0"'

spec_summary
