#!/usr/bin/env bash
# Minimal RSpec-flavoured test DSL for the freeloader scripts.
#
#   describe "benchmark.sh"
#     context "when a provider is not free"
#       it "excludes it"
#         expect_contains "$out" "foo"
#
# No dependencies beyond bash/coreutils. Every spec file sources this, runs its
# examples, and exits non-zero if any failed.

set -uo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FIXTURES="$PROJECT_DIR/tests/fixtures"

EXAMPLES_RUN=0
EXAMPLES_FAILED=0
FAILURE_LOG=""
CURRENT_EXAMPLE=""
INDENT=""

if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  C_RED=$'\033[31m'; C_GREEN=$'\033[32m'; C_GREY=$'\033[90m'; C_BOLD=$'\033[1m'; C_OFF=$'\033[0m'
else
  C_RED=""; C_GREEN=""; C_GREY=""; C_BOLD=""; C_OFF=""
fi

describe() { printf '\n%s%s%s\n' "$C_BOLD" "$1" "$C_OFF"; INDENT="  "; }
context()  { printf '%s%s%s%s\n' "  " "$C_GREY" "$1" "$C_OFF"; INDENT="    "; }

# it "<description>" '<body>'  — the body is evaluated in the *current* shell
# (not a subshell) so expect_* failures inside it propagate to the counters.
it() {
  CURRENT_EXAMPLE="$1"
  EXAMPLES_RUN=$((EXAMPLES_RUN + 1))
  EXAMPLE_FAILED=0
  eval "$2"
  if [ "$EXAMPLE_FAILED" -eq 0 ]; then
    printf '%s%s✓%s %s\n' "$INDENT" "$C_GREEN" "$C_OFF" "$CURRENT_EXAMPLE"
  else
    EXAMPLES_FAILED=$((EXAMPLES_FAILED + 1))
    printf '%s%s✗ %s%s\n' "$INDENT" "$C_RED" "$CURRENT_EXAMPLE" "$C_OFF"
  fi
}

_fail() {
  EXAMPLE_FAILED=1
  printf '%s  %s%s%s\n' "$INDENT" "$C_RED" "$1" "$C_OFF"
  FAILURE_LOG="${FAILURE_LOG}\n  ${CURRENT_EXAMPLE}: $1"
}

expect_eq() { # <actual> <expected> [label]
  if [ "$1" != "$2" ]; then
    _fail "${3:-expected} — got '$1', want '$2'"
  fi
}

expect_contains() { # <haystack> <needle> [label]
  case "$1" in
    *"$2"*) ;;
    *) _fail "${3:-expected output to contain} '$2' — got: $(printf '%s' "$1" | head -c 200)" ;;
  esac
}

expect_not_contains() { # <haystack> <needle> [label]
  case "$1" in
    *"$2"*) _fail "${3:-expected output NOT to contain} '$2'" ;;
  esac
}

expect_status() { # <actual_status> <expected_status> [label]
  if [ "$1" != "$2" ]; then
    _fail "${3:-expected exit status} $2 — got $1"
  fi
}

expect_gt() { # <actual> <floor> [label]
  if ! [ "$1" -gt "$2" ] 2>/dev/null; then
    _fail "${3:-expected} $1 > $2"
  fi
}

# Creates a throwaway dir with stub executables prepended to PATH, so specs can
# fake `opencode` / `curl` without touching the network. Call in a subshell.
with_stub_path() {
  STUB_BIN="$(mktemp -d)"
  PATH="$STUB_BIN:$PATH"
  export PATH STUB_BIN
}

# stub_bin <name> <<'EOF' ... EOF  — writes an executable stub from stdin.
stub_bin() {
  local name="$1"
  cat > "$STUB_BIN/$name"
  chmod +x "$STUB_BIN/$name"
}

spec_summary() {
  printf '\n%s examples, %s failures\n' "$EXAMPLES_RUN" "$EXAMPLES_FAILED"
  [ "$EXAMPLES_FAILED" -eq 0 ] || return 1
}
