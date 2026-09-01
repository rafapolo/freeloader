#!/usr/bin/env bash
# PreToolUse hook: pipe known-verbose Bash commands through scripts/cap.sh so
# their output never enters the conversation whole.
#
# It has to be PreToolUse. PostToolUse fires after the tool has already run and
# cannot modify the result — by the time it sees a 40k-token test log, the log
# is in the conversation and the money is spent. PreToolUse is the only event
# that can change what runs, via hookSpecificOutput.updatedInput.
#
# Rewriting a command that Claude is about to run is genuinely invasive, so the
# rules are narrow on purpose:
#
#   * only commands whose first word is on the verbose allowlist below — test
#     runners, builders, installers. Those are the ones that produce five
#     figures of output and are read for a one-line verdict.
#   * nothing containing a pipe, redirect, subshell, background, or command
#     separator. Wrapping those changes their meaning, and the wrapper is not
#     worth a single misparsed command.
#   * `set -o pipefail` so the exit status stays the command's own. A test
#     suite that fails must still read as failed; a cap that swallowed the exit
#     code would be far worse than one that saved no tokens.
#
# Anything unrecognised exits 0 with no output and runs exactly as written.
# Disable entirely with FREELOADER_CAP=0.
set -uo pipefail

[ "${FREELOADER_CAP:-1}" = "0" ] && exit 0

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CAP="$ROOT/scripts/cap.sh"

command -v jq >/dev/null 2>&1 || exit 0
[ -x "$CAP" ] || exit 0

payload="$(cat)"
tool=$(printf '%s' "$payload" | jq -r '.tool_name // empty' 2>/dev/null) || exit 0
[ "$tool" = "Bash" ] || exit 0

cmd=$(printf '%s' "$payload" | jq -r '.tool_input.command // empty' 2>/dev/null)
[ -n "$cmd" ] || exit 0

# Already shaped by the caller, or too structurally involved to wrap safely.
case "$cmd" in
  *'|'*|*'>'*|*'<'*|*'&'*|*';'*|*'`'*|*'$('*|*$'\n'*) exit 0 ;;
esac
# Already going through the cap (a re-entered command, or the user did it).
case "$cmd" in
  *cap.sh*) exit 0 ;;
esac

# Verbose by nature: read for a verdict, not for the text.
_verbose='^[[:space:]]*(npm|npx|yarn|pnpm|pytest|tox|nox|cargo|go|make|mvn|gradle|gradlew|\./gradlew|jest|vitest|tsc|eslint|rspec|bundle|phpunit|composer|dotnet|swift|bazel|terraform|ansible-playbook|docker|docker-compose|pip|pip3|poetry|uv|python|python3|ruby|node|deno|bun)([[:space:]]|$)'
printf '%s' "$cmd" | grep -Eq -- "$_verbose" || exit 0

# Only the sub-commands that actually produce a wall of output. `npm ls` or
# `go version` gain nothing from being wrapped and would just add a process.
_noisy='(test|tests|check|build|compile|install|ci|run|lint|clippy|fmt|audit|plan|apply|migrate|spec|bench|coverage|typecheck|tsc|e2e|start|watch)([[:space:]]|$)'
case "$cmd" in
  make|make\ *|python\ *|python3\ *|node\ *|ruby\ *|deno\ *|bun\ *|npx\ *|pytest*|rspec*|jest*|vitest*|tsc*|eslint*) ;;
  *) printf '%s' "$cmd" | grep -Eq -- "$_noisy" || exit 0 ;;
esac

wrapped="set -o pipefail; { $cmd ; } 2>&1 | $(printf '%q' "$CAP")"

printf '%s' "$payload" | jq -c --arg c "$wrapped" '{
  hookSpecificOutput: {
    hookEventName: "PreToolUse",
    updatedInput: (.tool_input + {command: $c})
  }
}'
exit 0
