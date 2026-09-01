#!/usr/bin/env bash
# Specs for hooks/intercept-hook.sh — answering a trivial prompt before the
# Claude turn exists.
#
# This is the only component that can produce an answer the user did not know
# was coming from somewhere else, and the only one that can stop Claude from
# running at all. Almost every example below is about the ways it must NOT
# fire, and about failing open when anything is off.
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/spec_helper.sh"

# intercept <prompt> [behaviour] [VAR=VAL ...]
# Echoes "<stdout>\n---\n<status>\n---\n<usage log>".
intercept() {
  local prompt="$1" behaviour="${2:-ok}"
  shift 2 2>/dev/null || shift 1
  (
    with_stub_path
    stub_opencode
    export RUN_BEHAVIOUR="$behaviour"
    printf '%s' '[{"model":"opencode/only","latency_ms":1000,"ok":true}]' > "$STUB_BIN/cache.json"
    export OPENCODE_FREE_CACHE="$STUB_BIN/cache.json" OPENCODE_FREE_CACHE_MAX_AGE=99999
    export FREELOADER_USAGE_LOG="$STUB_BIN/usage.jsonl"
    export FREELOADER_STATE="$STUB_BIN/state.json"
    printf 'x%.0s' $(seq 1 4000) > "$STUB_BIN/transcript.jsonl"
    for kv in "$@"; do export "${kv?}"; done
    payload=$(jq -cn --arg p "$prompt" --arg t "$STUB_BIN/transcript.jsonl" \
      '{user_prompt:$p, transcript_path:$t}')
    out=$(printf '%s' "$payload" | "$PROJECT_DIR/hooks/intercept-hook.sh" 2>/dev/null); status=$?
    # The trailing sentinel is load-bearing: command substitution strips the
    # final newline, so a last field that is empty leaves a dangling "---" glued
    # onto the previous one — and the field before it then silently fails to
    # compare equal to anything.
    printf '%s\n---\n%s\n---\n%s\n---\nEOR' "$out" "$status" "$(cat "$STUB_BIN/usage.jsonl" 2>/dev/null)"
  )
}

part() { printf '%s' "$1" | awk -v n="$2" 'BEGIN{RS="\n---\n"} NR==n'; }

describe "intercept-hook.sh — answering without a Claude turn"

  context "with a trivial self-contained question"

    # Exit 2 is what actually stops the turn; without it the answer is printed
    # and Claude runs anyway, which is strictly worse than not intercepting.
    it "blocks the turn" '
      r=$(intercept "what is the capital of Portugal")
      expect_status "$(part "$r" 2)" "2"
      d=$(printf "%s" "$(part "$r" 1)" | jq -r ".hookSpecificOutput.permissionDecision")
      expect_eq "$d" "deny"'

    it "shows the answer to the user" '
      r=$(intercept "what is the capital of Portugal" echo)
      reason=$(printf "%s" "$(part "$r" 1)" | jq -r ".hookSpecificOutput.permissionDecisionReason")
      expect_contains "$reason" "capital of Portugal"'

    # The user asked Claude and is getting an answer from somewhere else. That
    # has to be visible in the answer itself, not only in a log.
    it "says a free model answered" '
      r=$(intercept "what is the capital of Portugal")
      reason=$(printf "%s" "$(part "$r" 1)" | jq -r ".hookSpecificOutput.permissionDecisionReason")
      expect_contains "$reason" "free model"'

    it "tells the user how to get Claude instead" '
      r=$(intercept "what is the capital of Portugal")
      reason=$(printf "%s" "$(part "$r" 1)" | jq -r ".hookSpecificOutput.permissionDecisionReason")
      expect_contains "$reason" "claude,"'

describe "intercept-hook.sh — when it must not fire"

  context "with a prompt that needs the conversation"

    it "lets it through to Claude" '
      r=$(intercept "why did that test fail")
      expect_status "$(part "$r" 2)" "0"
      expect_eq "$(part "$r" 1)" "" "expected no hook output at all"'

    it "lets a task through" '
      r=$(intercept "fix the failing test")
      expect_status "$(part "$r" 2)" "0"'

  context "with a prompt addressed to Claude"

    it "never intercepts it" '
      r=$(intercept "claude, what is 2+2")
      expect_status "$(part "$r" 2)" "0"'

  context "with a prompt carrying personal data"

    it "does not route it and does not block" '
      r=$(intercept "what is the domain of rafael.polo@gmail.com")
      expect_status "$(part "$r" 2)" "0"'

describe "intercept-hook.sh — failing open"

  # Every one of these ends with Claude answering normally. A hook that blocks
  # a turn without producing an answer would strand the user completely.
  context "when the free model fails"

    it "passes the prompt through instead of blocking" '
      r=$(intercept "what is the capital of Portugal" all_fail)
      expect_status "$(part "$r" 2)" "0"
      expect_eq "$(part "$r" 1)" "" "expected no block on a failed route"'

    it "does the same when the reply is empty" '
      r=$(intercept "what is the capital of Portugal" empty_reply)
      expect_status "$(part "$r" 2)" "0"'

    # A tool-enabled fallback answer must be refused here as everywhere else.
    it "does the same when the sandbox did not load" '
      r=$(intercept "what is the capital of Portugal" agent_fallback)
      expect_status "$(part "$r" 2)" "0"'

  context "when switched off"

    it "does nothing" '
      r=$(intercept "what is the capital of Portugal" ok FREELOADER_INTERCEPT=0)
      expect_status "$(part "$r" 2)" "0"
      expect_eq "$(part "$r" 1)" ""'

  context "with unusable input"

    it "ignores a payload with no prompt" '
      out=$(printf "%s" "{}" | "$PROJECT_DIR/hooks/intercept-hook.sh" 2>/dev/null); status=$?
      expect_status "$status" "0"
      expect_eq "$out" ""'

describe "intercept-hook.sh — accounting"

  context "after an intercepted prompt"

    it "records the conversation size it saved re-sending" '
      r=$(intercept "what is the capital of Portugal")
      ctx=$(printf "%s" "$(part "$r" 3)" | jq -r ".saved.input_tokens")
      expect_gt "$ctx" "500"'

    it "books it as mode=hook with no routing cost" '
      r=$(intercept "what is the capital of Portugal")
      m=$(printf "%s" "$(part "$r" 3)" | jq -r ".mode")
      expect_eq "$m" "hook"
      c=$(printf "%s" "$(part "$r" 3)" | jq -r ".cost.usd")
      expect_eq "$c" "0"'

    # The whole point of moving the call site out of the turn.
    it "nets positive, unlike the same route made inside a turn" '
      r=$(intercept "what is the capital of Portugal")
      pos=$(printf "%s" "$(part "$r" 3)" | jq -r ".net_usd > 0")
      expect_eq "$pos" "true"'

spec_summary
