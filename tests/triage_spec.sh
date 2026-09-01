#!/usr/bin/env bash
# Specs for scripts/triage.sh — "can this be answered with no context at all?"
#
# The asymmetry that shapes every example here: a false negative costs nothing
# (Claude answers, exactly as it would have anyway), while a false positive
# means a free model answers a question about the user's repo without ever
# having seen it — and the Claude turn that would have caught that never runs.
# So the "must reach Claude" examples are the load-bearing ones.
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/spec_helper.sh"

routes() { # <prompt> — answerable with no context
  "$PROJECT_DIR/scripts/triage.sh" "$1" >/dev/null 2>&1
  expect_status "$?" "0" "expected '$1' to be routable without context"
}

reaches_claude() { # <prompt> — must not be intercepted
  local why; why=$("$PROJECT_DIR/scripts/triage.sh" "$1" 2>/dev/null); local st=$?
  expect_status "$st" "1" "expected '$1' to reach Claude"
  [ -n "$why" ] || _fail "expected a stated reason for refusing '$1'"
}

describe "triage.sh — self-contained questions"

  context "with a general-knowledge lookup"

    it "accepts a plain factual question" '
      routes "what is the capital of Portugal"
      routes "who was Ada Lovelace"'

    it "accepts a contraction" '
      routes "what is the boiling point of water"
      routes "whats the tallest mountain"'

    it "accepts a conversion or a calculation" '
      routes "convert 72f to celsius"
      routes "how many meters in a mile"
      routes "17 * 23"'

    it "accepts a language command" '
      routes "translate bom dia to japanese"
      routes "define ephemeral"'

describe "triage.sh — anything touching the conversation"

  # Each of these is answerable-sounding in isolation, which is exactly the
  # danger: a free model with no context will answer them anyway, fluently and
  # wrongly.
  context "with a word pointing outside the prompt"

    it "refuses demonstratives" '
      reaches_claude "what is this function doing"
      reaches_claude "why did that test fail"
      reaches_claude "summarize the output above"'

    it "refuses possessives" '
      reaches_claude "what does my config say"
      reaches_claude "how big is our test suite"'

    it "refuses follow-ups" '
      reaches_claude "why"
      reaches_claude "keep going"'

  context "with a request for work rather than a fact"

    it "refuses task verbs" '
      reaches_claude "run the tests"
      reaches_claude "fix the bug in the parser"
      reaches_claude "add a flag for verbose output"'

  context "with a reference to the filesystem"

    it "refuses a path or a filename" '
      reaches_claude "what is in src/main.py"
      reaches_claude "what does ~/.zshrc do"'

    it "refuses code" '
      reaches_claude "what does \`git rebase\` do"'

  # The user has to be able to force a real turn, or an intercept that answers
  # badly would be inescapable.
  context "when the user addresses Claude"

    it "always defers, even on an otherwise routable question" '
      reaches_claude "claude, what is 2+2"
      reaches_claude "what do you think the capital of Portugal is"'

describe "triage.sh — the guards still apply"

  context "with a prompt carrying personal data"

    it "refuses it before any routing is attempted" '
      reaches_claude "what is the domain of rafael.polo@gmail.com"'

  context "with a long or pasted prompt"

    it "refuses anything over the length limit" '
      reaches_claude "what is $(printf "a%.0s" $(seq 1 200))"'

    it "refuses anything multi-line" '
      reaches_claude "what is this
      second line"'

describe "triage.sh — shape allowlist"

  # The allowlist is short on purpose: everything not positively recognised
  # goes to Claude. These are plausible prompts that are still not on it.
  context "with an unrecognised shape"

    it "defers rather than guessing" '
      reaches_claude "tell me about the roman empire"
      reaches_claude "capital of Portugal"'

spec_summary
