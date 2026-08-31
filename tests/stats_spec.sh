#!/usr/bin/env bash
# Specs for scripts/stats.sh — aggregating the usage log route.sh writes.
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/spec_helper.sh"

# stats_on <jsonl-log-contents> [args...]
stats_on() {
  local log_contents="$1"; shift
  (
    STUB_BIN="$(mktemp -d)"
    printf '%s\n' "$log_contents" > "$STUB_BIN/usage.jsonl"
    FREELOADER_USAGE_LOG="$STUB_BIN/usage.jsonl" "$PROJECT_DIR/scripts/stats.sh" "$@" 2>&1
    rm -rf "$STUB_BIN"
  )
}

rec() { # rec <model> <in-tokens> <out-tokens> <usd> <ts>
  jq -cn --arg m "$1" --argjson i "$2" --argjson o "$3" --argjson u "$4" --arg ts "$5" \
    '{ts:$ts, ok:true, model:$m, elapsed_ms:1500,
      free_tokens:{input:400,output:50,total:450},
      saved:{baseline_model:"claude-sonnet-5", input_tokens:$i, output_tokens:$o, usd:$u}}'
}

LOG="$(rec opencode/fast 100 200 0.0022 2026-08-01T10:00:00Z)
$(rec opencode/fast 100 200 0.0022 2026-08-02T10:00:00Z)
$(rec opencode/slow 50 100 0.0011 2026-08-03T10:00:00Z)
{\"ts\":\"2026-08-04T10:00:00Z\",\"ok\":false,\"failed\":[\"opencode/slow: timeout\"]}"

describe "stats.sh — aggregation"

  context "with a log of successful and failed routes"

    it "counts the successful routes" '
      out=$(stats_on "$LOG" --json)
      expect_eq "$(printf "%s" "$out" | jq -r ".routes_ok")" "3"'

    it "counts the failures separately, not as savings" '
      out=$(stats_on "$LOG" --json)
      expect_eq "$(printf "%s" "$out" | jq -r ".routes_failed")" "1"'

    it "sums the tokens that never went to Claude" '
      out=$(stats_on "$LOG" --json)
      expect_eq "$(printf "%s" "$out" | jq -r ".saved.input_tokens")" "250"
      expect_eq "$(printf "%s" "$out" | jq -r ".saved.output_tokens")" "500"'

    it "sums the dollar estimate" '
      out=$(stats_on "$LOG" --json)
      expect_eq "$(printf "%s" "$out" | jq -r ".saved.usd")" "0.0055"'

    it "reports the free tokens spent instead" '
      out=$(stats_on "$LOG" --json)
      expect_eq "$(printf "%s" "$out" | jq -r ".free_tokens_spent")" "1350"'

    it "breaks the total down by model, busiest first" '
      out=$(stats_on "$LOG" --json)
      expect_eq "$(printf "%s" "$out" | jq -r ".by_model[0].model")" "opencode/fast"
      expect_eq "$(printf "%s" "$out" | jq -r ".by_model[0].routes")" "2"'

    it "names the baseline model the estimate is priced against" '
      out=$(stats_on "$LOG" --json)
      expect_eq "$(printf "%s" "$out" | jq -r ".baseline_model")" "claude-sonnet-5"'

  context "with a --since filter"

    it "counts only records at or after the cutoff" '
      out=$(stats_on "$LOG" --json --since 2026-08-03T00:00:00Z)
      expect_eq "$(printf "%s" "$out" | jq -r ".routes_ok")" "1"'

describe "stats.sh — robustness"

  context "with no log at all"

    it "says so instead of failing" '
      out=$(FREELOADER_USAGE_LOG="/nonexistent/nope.jsonl" "$PROJECT_DIR/scripts/stats.sh" 2>&1); status=$?
      expect_status "$status" "0"
      expect_contains "$out" "No routes logged yet"'

  context "with a truncated or corrupt line in the log"

    # The log is appended to by concurrent routes; a half-written line must not
    # take down the whole report.
    it "skips the bad line and still totals the good ones" '
      out=$(stats_on "$(rec opencode/fast 100 200 0.0022 2026-08-01T10:00:00Z)
{\"ts\":\"2026-08-02T10:00:00Z\",\"ok\":tr
$(rec opencode/fast 100 200 0.0022 2026-08-03T10:00:00Z)" --json)
      expect_eq "$(printf "%s" "$out" | jq -r ".routes_ok")" "2"'

describe "stats.sh — human output"

  context "by default"

    it "renders a readable summary rather than JSON" '
      out=$(stats_on "$LOG")
      expect_contains "$out" "routed 3 of 4 prompts"
      expect_not_contains "$out" "{"'

    it "names each model that answered" '
      out=$(stats_on "$LOG")
      expect_contains "$out" "opencode/fast"'

spec_summary
