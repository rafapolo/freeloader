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

# stub_opencode — writes a fake `opencode` that speaks the real CLI's contract:
# it parses flags (rather than assuming argument positions, which shift whenever
# lib.sh's oc_run changes) and emits a `--format json` event stream.
#
# Behaviour is chosen per-call via $RUN_BEHAVIOUR:
#   ok             answer normally
#   all_fail       exit non-zero
#   fail_first     exit non-zero for the model named in $FAIL_MODEL
#   error_stream   exit 0 but emit only {"type":"error"} — the real failure mode
#                  that a naive "exit 0 means success" check misreads as an answer
#   no_finish      emit text but never step_finish (cut off mid-answer)
#   empty_reply    emit step_finish with no text at all
#   agent_fallback answer, but warn on stderr that the sandboxed agent didn't load
#   slow           hang, so timeout handling can be exercised
#   echo           reply with the prompt it received
stub_opencode() {
  stub_bin opencode <<STUB
#!/usr/bin/env bash
sub="\$1"; shift

if [ "\$sub" = "models" ]; then
  # \$MODELS_EMPTY simulates a catalogue with no free models at all.
  [ -n "\${MODELS_EMPTY:-}" ] && exit 0
  cat "$FIXTURES/models_verbose.txt"; exit 0
fi
[ "\$sub" = "run" ] || exit 0

model=""; prompt=""; agent=""
while [ \$# -gt 0 ]; do
  case "\$1" in
    -m|--model)  model="\$2"; shift 2 ;;
    --agent)     agent="\$2"; shift 2 ;;
    --dir|--format) shift 2 ;;
    --pure)      shift ;;
    *)           prompt="\$1"; shift ;;
  esac
done

emit_text()   { printf '{"type":"text","part":{"text":"%s"}}\n' "\$1"; }
emit_finish() { printf '{"type":"step_finish","part":{"reason":"stop","tokens":{"input":100,"output":20,"total":120}}}\n'; }
emit_error()  { printf '{"type":"error","error":{"name":"UnknownError","data":{"message":"%s"}}}\n' "\$1"; }

# Answer whichever probe benchmark.sh is running, so ranking specs work.
case "\$prompt" in
  *pong*) answer="pong" ;;
  *17*)   answer="391" ;;
  *)      answer="4" ;;
esac

case "\${RUN_BEHAVIOUR:-ok}" in
  all_fail)     exit 1 ;;
  fail_first)   [ "\$model" = "\${FAIL_MODEL:-}" ] && exit 1 ;;
  error_stream) emit_error "Unexpected server error."; exit 0 ;;
  no_finish)    emit_text "\$answer"; exit 0 ;;
  empty_reply)  emit_finish; exit 0 ;;
  agent_fallback)
    echo '! agent "freeloader" not found. Falling back to default agent' >&2 ;;
  slow)         sleep 10 ;;
  echo)         answer="answered: \$prompt" ;;
esac

# Per-model pacing, so latency ranking has something to sort on.
case "\$model" in
  */brace-in-string) sleep 0.3 ;;
  */go-free)         sleep 0.2 ;;
  */big-pickle)      sleep 0.1 ;;
esac

emit_text "\$answer"
emit_finish
STUB
}

spec_summary() {
  printf '\n%s examples, %s failures\n' "$EXAMPLES_RUN" "$EXAMPLES_FAILED"
  [ "$EXAMPLES_FAILED" -eq 0 ] || return 1
}
