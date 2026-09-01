#!/usr/bin/env bash
# Specs for scripts/cap.sh and hooks/cap-hook.sh — keeping a large command
# output out of the conversation.
#
# The failure that matters here is not "saved fewer tokens than it could have".
# It is destroying the one line someone needed, or masking a non-zero exit so a
# failing build reads as green. Most of these examples are about that.
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/spec_helper.sh"

# cap <<< text — runs cap.sh with a stubbed opencode and an isolated log.
cap() { # <stdin text> [VAR=VAL ...]
  local text="$1"; shift
  (
    with_stub_path
    stub_opencode
    export RUN_BEHAVIOUR=ok
    printf '%s' '[{"model":"opencode/only","latency_ms":1000,"ok":true}]' > "$STUB_BIN/cache.json"
    export OPENCODE_FREE_CACHE="$STUB_BIN/cache.json" OPENCODE_FREE_CACHE_MAX_AGE=99999
    export FREELOADER_USAGE_LOG="$STUB_BIN/usage.jsonl"
    export FREELOADER_CAP_DIR="$STUB_BIN/kept"
    for kv in "$@"; do export "${kv?}"; done
    out=$(printf '%s' "$text" | "$PROJECT_DIR/scripts/cap.sh" 2>/dev/null)
    # Trailing sentinel: command substitution strips the final newline, so an
    # empty last field would leave a dangling "---" attached to the field
    # before it and quietly break every comparison against it.
    printf '%s\n---\n%s\n---\nEOR' "$out" "$(cat "$STUB_BIN/usage.jsonl" 2>/dev/null)"
  )
}

part() { printf '%s' "$1" | awk -v n="$2" 'BEGIN{RS="\n---\n"} NR==n'; }

big_output() { # <lines> — noise with a failure buried at the end
  local n="$1" i=1
  while [ "$i" -le "$n" ]; do echo "compiling module_$i ... ok"; i=$((i + 1)); done
  echo "ERROR: linker failed on module_42: undefined reference to foo()"
}

describe "cap.sh — small output"

  context "when the output is under the threshold"

    it "passes it through byte for byte" '
      out=$(printf "hello\nworld\n" | "$PROJECT_DIR/scripts/cap.sh" | od -An -c | tr -d " \n")
      want=$(printf "hello\nworld\n" | od -An -c | tr -d " \n")
      expect_eq "$out" "$want" "expected an untouched pass-through"'

    it "adds no freeloader banner" '
      r=$(cap "just a little output")
      expect_not_contains "$(part "$r" 1)" "freeloader"'

    it "logs nothing — there was no saving to claim" '
      r=$(cap "just a little output")
      expect_eq "$(part "$r" 2)" "" "expected an empty ledger"'

describe "cap.sh — large output"

  context "when the output is over the threshold"

    it "shrinks it substantially" '
      big=$(big_output 800)
      r=$(cap "$big")
      capped=${#r}
      if [ "$capped" -ge "${#big}" ]; then _fail "expected the output to shrink"; fi'

    it "keeps the head and the tail" '
      r=$(cap "$(big_output 800)")
      expect_contains "$(part "$r" 1)" "compiling module_1 "
      expect_contains "$(part "$r" 1)" "compiling module_800 "'

    # The entire reason anyone reads a build log. A summary can paraphrase a
    # failure out of existence; these lines are copied through verbatim.
    it "keeps every line that looks like a failure" '
      r=$(cap "$(big_output 800)")
      expect_contains "$(part "$r" 1)" "linker failed on module_42"'

    it "says how much it held back" '
      r=$(cap "$(big_output 800)")
      expect_contains "$(part "$r" 1)" "held out of context"'

  # Nothing is ever only summarised. If the cap ate the one line that mattered,
  # there has to be somewhere to go and read it.
  context "with the full output"

    it "writes it to a file and names the path" '
      r=$(cap "$(big_output 800)")
      path=$(printf "%s" "$(part "$r" 1)" | sed -n "s/.*full output: //p" | head -1)
      [ -n "$path" ] || _fail "expected a path to the full output"
      [ -s "$path" ] || _fail "expected the full output to exist at $path"
      grep -q "module_400" "$path" || _fail "expected the full output to be complete"'

describe "cap.sh — the summary"

  context "when a free model summarises the excerpt"

    it "includes the summary" '
      r=$(cap "$(big_output 800)")
      expect_contains "$(part "$r" 1)" "free-model summary"'

    # A head -c excerpt would show the model only the first lines, and a build
    # that fails on its last line then gets summarised as clean — a wrong
    # verdict printed directly above the error that disproves it.
    it "shows the model the failure lines, not just the first bytes" '
      r=$(cap "$(big_output 800)" RUN_BEHAVIOUR=echo)
      expect_contains "$(part "$r" 1)" "linker failed"'

  context "when no model is available"

    it "still caps, structurally, and says so on the ledger" '
      r=$(cap "$(big_output 800)" RUN_BEHAVIOUR=all_fail)
      expect_contains "$(part "$r" 1)" "held out of context"
      s=$(printf "%s" "$(part "$r" 2)" | jq -r ".summarized")
      expect_eq "$s" "false"'

    it "never claims a free model did work it did not do" '
      r=$(cap "$(big_output 800)" RUN_BEHAVIOUR=all_fail)
      expect_not_contains "$(part "$r" 1)" "free-model summary"'

describe "cap.sh — ledger"

  context "after capping"

    it "records the mode and a positive net" '
      r=$(cap "$(big_output 800)")
      m=$(printf "%s" "$(part "$r" 2)" | jq -r ".mode")
      expect_eq "$m" "cap"
      pos=$(printf "%s" "$(part "$r" 2)" | jq -r ".net_usd > 0")
      expect_eq "$pos" "true"'

    # Unlike a route made inside a turn, this one adds no request of its own.
    it "records no routing cost, because no extra turn happened" '
      r=$(cap "$(big_output 800)")
      c=$(printf "%s" "$(part "$r" 2)" | jq -r ".cost.usd")
      expect_eq "$c" "0"'

    it "logs exactly one record, not one per internal route" '
      r=$(cap "$(big_output 800)")
      n=$(printf "%s" "$(part "$r" 2)" | grep -c . || true)
      expect_eq "$n" "1"'

describe "cap-hook.sh — which commands get wrapped"

  hook() { # <command> — the rewritten command, or empty
    printf '{"tool_name":"Bash","tool_input":{"command":%s}}' "$(jq -Rn --arg c "$1" '$c')" \
      | "$PROJECT_DIR/hooks/cap-hook.sh" 2>/dev/null \
      | jq -r '.hookSpecificOutput.updatedInput.command // ""' 2>/dev/null
  }

  context "with a command known to be verbose"

    it "pipes it through the cap" '
      expect_contains "$(hook "npm test")" "cap.sh"
      expect_contains "$(hook "pytest -q")" "cap.sh"
      expect_contains "$(hook "cargo build --release")" "cap.sh"'

    # Without pipefail the pipeline reports the cap exit status, and a failing
    # test suite silently reads as passing — far worse than saving nothing.
    it "preserves the exit status with pipefail" '
      expect_contains "$(hook "npm test")" "set -o pipefail"'

  context "with anything else"

    it "leaves quiet commands alone" '
      expect_eq "$(hook "git status")" ""
      expect_eq "$(hook "ls -la")" ""
      expect_eq "$(hook "go version")" ""'

    # Wrapping a command that already has a pipe or a redirect would change
    # what it means, and no token saving justifies that.
    it "leaves anything already piped or redirected alone" '
      expect_eq "$(hook "npm test | head -20")" ""
      expect_eq "$(hook "npm test > out.txt")" ""
      expect_eq "$(hook "npm test && echo done")" ""'

    it "does not wrap a command twice" '
      expect_eq "$(hook "npm test 2>&1 | /x/cap.sh")" ""'

    it "ignores non-Bash tools" '
      out=$(printf "%s" "{\"tool_name\":\"Read\",\"tool_input\":{\"file_path\":\"/x\"}}" \
        | "$PROJECT_DIR/hooks/cap-hook.sh" 2>/dev/null)
      expect_eq "$out" ""'

  context "when disabled"

    it "does nothing at all" '
      out=$(printf "%s" "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"npm test\"}}" \
        | FREELOADER_CAP=0 "$PROJECT_DIR/hooks/cap-hook.sh" 2>/dev/null)
      expect_eq "$out" ""'

spec_summary
