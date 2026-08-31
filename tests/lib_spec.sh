#!/usr/bin/env bash
# Specs for scripts/lib.sh — the portable timeout wrapper.
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/spec_helper.sh"
. "$PROJECT_DIR/scripts/lib.sh"

describe "lib.sh — run_with_timeout"

  context "with GNU timeout available"

    it "returns the command's own exit status on success" '
      out=$(run_with_timeout 5 true); status=$?
      expect_status "$status" "0"'

    it "propagates a non-zero exit status" '
      run_with_timeout 5 false >/dev/null 2>&1; status=$?
      expect_status "$status" "1"'

    it "passes stdout through to the caller" '
      out=$(run_with_timeout 5 echo "hello from the command")
      expect_contains "$out" "hello from the command"'

    it "returns 124 when the command overruns its budget" '
      run_with_timeout 1 sleep 5 >/dev/null 2>&1; status=$?
      expect_status "$status" "124" "expected GNU timeout exit code"'

  context "when neither timeout nor gtimeout exists (stock macOS)"

    # This is the case that used to break the whole skill: a missing `timeout`
    # exits 127, which callers read as "this model is broken" — silently
    # failing every model. The pure-shell watchdog has to cover it.

    it "still runs the command and returns its status" '
      out=$(TIMEOUT_BIN="" run_with_timeout 5 echo "watchdog path")
      status=$?
      expect_status "$status" "0"
      expect_contains "$out" "watchdog path"'

    it "still propagates a non-zero exit status" '
      ( TIMEOUT_BIN=""; run_with_timeout 5 false ) >/dev/null 2>&1; status=$?
      expect_status "$status" "1"'

    it "still kills an overrunning command and returns 124" '
      ( TIMEOUT_BIN=""; run_with_timeout 1 sleep 6 ) >/dev/null 2>&1; status=$?
      expect_status "$status" "124"'

    it "never returns 127 for a command that exists" '
      ( TIMEOUT_BIN=""; run_with_timeout 2 true ) >/dev/null 2>&1; status=$?
      expect_not_contains "$status" "127" "127 would be misread as a broken model"'

spec_summary
