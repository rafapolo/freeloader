#!/usr/bin/env bash
# Shared helpers for the freeloader scripts. Source, don't execute.

# GNU `timeout` is NOT part of a stock macOS — it only shows up via
# `brew install coreutils` (as `timeout` and/or `gtimeout`). Without this
# detection, a missing `timeout` fails with exit 127 ("command not found"),
# which the callers below would otherwise read as "this model is broken" —
# silently marking every single model as failed. Resolve it once, and fall
# back to a pure-shell watchdog when neither binary exists.
if command -v timeout >/dev/null 2>&1; then
  TIMEOUT_BIN="timeout"
elif command -v gtimeout >/dev/null 2>&1; then
  TIMEOUT_BIN="gtimeout"
else
  TIMEOUT_BIN=""
fi

# run_with_timeout <seconds> <command...>
# Returns the command's exit status, or 124 on timeout (matching GNU timeout).
run_with_timeout() {
  local secs="$1"; shift

  if [ -n "$TIMEOUT_BIN" ]; then
    "$TIMEOUT_BIN" "$secs" "$@"
    return $?
  fi

  # Fallback watchdog: run in the background, poll once a second, escalate
  # TERM -> KILL if it overruns. stdout/stderr still flow to the caller (and
  # into any surrounding command substitution) because the child inherits them.
  "$@" &
  local cmd_pid=$! waited=0
  while kill -0 "$cmd_pid" 2>/dev/null; do
    if [ "$waited" -ge "$secs" ]; then
      kill -TERM "$cmd_pid" 2>/dev/null
      sleep 1
      kill -KILL "$cmd_pid" 2>/dev/null
      wait "$cmd_pid" 2>/dev/null
      return 124
    fi
    sleep 1
    waited=$((waited + 1))
  done
  wait "$cmd_pid"
  return $?
}
