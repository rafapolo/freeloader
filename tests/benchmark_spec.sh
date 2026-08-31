#!/usr/bin/env bash
# Specs for scripts/benchmark.sh — free-model discovery, probing and ranking.
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/spec_helper.sh"

# Runs benchmark.sh against a stubbed `opencode`, with a scratch cache.
# $1 = $RUN_BEHAVIOUR for the stub (see spec_helper.sh). Extra args are exported
# as VAR=VALUE into the benchmark's environment.
run_benchmark() {
  local behaviour="${1:-ok}"; shift 2>/dev/null || true
  (
    with_stub_path
    stub_opencode
    export RUN_BEHAVIOUR="$behaviour"
    export OPENCODE_FREE_CACHE="$STUB_BIN/cache.json"
    for kv in "$@"; do export "${kv?}"; done
    "$PROJECT_DIR/scripts/benchmark.sh" 2>/dev/null
  )
}

OUT_OK="$(run_benchmark ok)"
OUT_FAIL="$(run_benchmark all_fail)"
OUT_ERRSTREAM="$(run_benchmark error_stream)"

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

describe "benchmark.sh — probing"

  context "when a model passes both probes"

    it "scores it 2 and marks it ok" '
      n=$(printf "%s" "$OUT_OK" | jq "[.[] | select(.score == 2 and .ok)] | length")
      expect_eq "$n" "4"'

    it "records which probe did what, so a ranking can be explained" '
      p=$(printf "%s" "$OUT_OK" | jq -r ".[0].probes | .responds and .follows_instruction")
      expect_eq "$p" "true"'

  # The regression that matters most: `opencode run` exits 0 even when the
  # entire stream is an error event. Scoring on exit status alone would rank a
  # totally broken model as the fastest working one.
  context "when a model exits 0 but emits only an error event"

    it "does not treat it as working" '
      ok=$(printf "%s" "$OUT_ERRSTREAM" | jq "[.[] | select(.ok)] | length")
      expect_eq "$ok" "0" "expected an error-only stream to score as broken"'

    it "still lists the model rather than dropping it" '
      total=$(printf "%s" "$OUT_ERRSTREAM" | jq "length")
      expect_eq "$total" "4"'

  context "when a model answers but is cut off before step_finish"

    it "does not treat a truncated answer as a pass" '
      out=$(run_benchmark no_finish)
      ok=$(printf "%s" "$out" | jq "[.[] | select(.ok)] | length")
      expect_eq "$ok" "0"'

  context "when opencode falls back to the tool-enabled default agent"

    # Fail-closed: a correct-looking answer from an unsandboxed agent is worse
    # than no answer, because the sandbox is the whole privacy guarantee.
    it "refuses the result even though the model replied correctly" '
      out=$(run_benchmark agent_fallback)
      ok=$(printf "%s" "$out" | jq "[.[] | select(.ok)] | length")
      expect_eq "$ok" "0" "expected an unsandboxed run to be refused"'

describe "benchmark.sh — ranking"

  context "when every candidate answers both probes"

    it "sorts by ascending latency" '
      sorted=$(printf "%s" "$OUT_OK" | jq -r "[.[].latency_ms] | . == sort")
      expect_eq "$sorted" "true" "expected latencies sorted ascending"'

    it "records a positive latency for each model" '
      n=$(printf "%s" "$OUT_OK" | jq "[.[] | select(.latency_ms > 0)] | length")
      expect_eq "$n" "4"'

  context "when every probe fails"

    it "marks them all not-ok rather than dropping them" '
      total=$(printf "%s" "$OUT_FAIL" | jq "length")
      ok=$(printf "%s" "$OUT_FAIL" | jq "[.[] | select(.ok)] | length")
      expect_eq "$total" "4"
      expect_eq "$ok" "0"'

spec_summary
