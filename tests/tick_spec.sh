#!/usr/bin/env bash
# Specs for scripts/tick.sh — the message-driven conserve-mode counter.
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/spec_helper.sh"

# tick_env <usage-behaviour> — sets up a scratch state file and a stubbed
# usage.sh, then echoes the scratch dir. Behaviours:
#   low   -> utilisation well under the threshold
#   high  -> 5h utilisation over the threshold
#   week  -> only the 7d window over the threshold
#   fail  -> usage.sh exits non-zero (no credentials / network down)
#   junk  -> usage.sh prints something that isn't JSON
tick_env() {
  local behaviour="$1" dir
  dir="$(mktemp -d)"
  mkdir -p "$dir/scripts"
  cp "$PROJECT_DIR/scripts/lib.sh" "$dir/scripts/lib.sh"
  cp "$PROJECT_DIR/scripts/tick.sh" "$dir/scripts/tick.sh"
  cat > "$dir/scripts/usage.sh" <<STUB
#!/usr/bin/env bash
case "$behaviour" in
  low)  echo '{"five_hour":{"status":"allowed","utilization":0.12},"seven_day":{"status":"allowed","utilization":0.20}}' ;;
  high) echo '{"five_hour":{"status":"allowed_warning","utilization":0.92},"seven_day":{"status":"allowed","utilization":0.20}}' ;;
  week) echo '{"five_hour":{"status":"allowed","utilization":0.10},"seven_day":{"status":"allowed_warning","utilization":0.85}}' ;;
  fail) exit 1 ;;
  junk) echo 'not json at all' ;;
esac
STUB
  chmod +x "$dir/scripts/usage.sh"
  printf '%s' "$dir"
}

# tick_n <dir> <times> — runs tick.sh N times, echoing the last output.
tick_n() {
  local dir="$1" n="$2" out=""
  local i=1
  while [ "$i" -le "$n" ]; do
    out=$(FREELOADER_STATE="$dir/state.json" FREELOADER_REFRESH_EVERY=5 "$dir/scripts/tick.sh")
    i=$((i + 1))
  done
  printf '%s' "$out"
}

describe "tick.sh — counting turns"

  context "on the turns between refreshes"

    it "increments the counter without calling usage.sh" '
      dir=$(tick_env low)
      out=$(tick_n "$dir" 1)
      expect_eq "$(printf "%s" "$out" | jq -r .turns_since_check)" "1"
      expect_eq "$(printf "%s" "$out" | jq -r ".last_check == null")" "true" "should not have refreshed yet"'

    it "keeps counting up to the refresh interval" '
      dir=$(tick_env low)
      out=$(tick_n "$dir" 4)
      expect_eq "$(printf "%s" "$out" | jq -r .turns_since_check)" "4"
      expect_eq "$(printf "%s" "$out" | jq -r ".last_check == null")" "true"'

  context "on the Nth turn"

    it "refreshes and resets the counter to zero" '
      dir=$(tick_env low)
      out=$(tick_n "$dir" 5)
      expect_eq "$(printf "%s" "$out" | jq -r .turns_since_check)" "0"
      expect_eq "$(printf "%s" "$out" | jq -r ".last_check != null")" "true" "expected a stored refresh"'

    it "starts counting again from the refreshed state" '
      dir=$(tick_env low)
      out=$(tick_n "$dir" 6)
      expect_eq "$(printf "%s" "$out" | jq -r .turns_since_check)" "1"'

describe "tick.sh — conserve mode"

  context "when utilisation is below the threshold"

    it "leaves conserve_mode off" '
      dir=$(tick_env low)
      out=$(tick_n "$dir" 5)
      expect_eq "$(printf "%s" "$out" | jq -r .conserve_mode)" "false"'

  context "when the 5h window crosses the threshold"

    it "turns conserve_mode on" '
      dir=$(tick_env high)
      out=$(tick_n "$dir" 5)
      expect_eq "$(printf "%s" "$out" | jq -r .conserve_mode)" "true"'

    it "records the utilisation that triggered it" '
      dir=$(tick_env high)
      out=$(tick_n "$dir" 5)
      expect_eq "$(printf "%s" "$out" | jq -r .last_check.five_hour.utilization)" "0.92"'

  context "when only the 7d window crosses the threshold"

    it "turns conserve_mode on as well" '
      dir=$(tick_env week)
      out=$(tick_n "$dir" 5)
      expect_eq "$(printf "%s" "$out" | jq -r .conserve_mode)" "true"'

  context "with a custom threshold"

    it "honours FREELOADER_UTIL_THRESHOLD" '
      dir=$(tick_env low)
      out=$(FREELOADER_STATE="$dir/state.json" FREELOADER_REFRESH_EVERY=1 \
            FREELOADER_UTIL_THRESHOLD=0.05 "$dir/scripts/tick.sh")
      expect_eq "$(printf "%s" "$out" | jq -r .conserve_mode)" "true" "0.12 should exceed a 0.05 threshold"'

describe "tick.sh — degradation"

  context "when usage.sh fails (no credentials, network down)"

    it "does not crash" '
      dir=$(tick_env fail)
      out=$(tick_n "$dir" 5)
      expect_contains "$out" "conserve_mode"'

    it "does not reset the counter, so the next turn retries" '
      dir=$(tick_env fail)
      out=$(tick_n "$dir" 5)
      expect_eq "$(printf "%s" "$out" | jq -r .turns_since_check)" "4" "should hold at N-1 and retry"'

    it "keeps the previous conserve_mode instead of guessing" '
      dir=$(tick_env fail)
      out=$(tick_n "$dir" 5)
      expect_eq "$(printf "%s" "$out" | jq -r .conserve_mode)" "false"'

  context "when usage.sh returns something that is not JSON"

    it "treats it as a failed refresh rather than corrupting state" '
      dir=$(tick_env junk)
      out=$(tick_n "$dir" 5)
      expect_eq "$(printf "%s" "$out" | jq -r .turns_since_check)" "4"
      expect_eq "$(printf "%s" "$out" | jq -r .conserve_mode)" "false"'

  context "when the state file is corrupt"

    it "recovers instead of failing" '
      dir=$(tick_env low)
      echo "{{{ not json" > "$dir/state.json"
      out=$(tick_n "$dir" 1)
      expect_eq "$(printf "%s" "$out" | jq -r .turns_since_check)" "1"'

describe "tick.sh — persistence"

  context "across separate invocations"

    it "writes valid JSON state to disk" '
      dir=$(tick_env low)
      tick_n "$dir" 2 >/dev/null
      jq -e . "$dir/state.json" >/dev/null 2>&1
      expect_status "$?" "0" "state file should be valid JSON"'

    it "retains last_check between refreshes" '
      dir=$(tick_env high)
      tick_n "$dir" 5 >/dev/null
      out=$(tick_n "$dir" 1)
      expect_eq "$(printf "%s" "$out" | jq -r ".last_check != null")" "true"
      expect_eq "$(printf "%s" "$out" | jq -r .conserve_mode)" "true" "conserve_mode should persist between refreshes"'

spec_summary
