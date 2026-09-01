#!/usr/bin/env bash
# Decides whether a prompt can be answered with NO conversation context.
#
# This is a much harder question than "is this prompt cheap", and it is asked
# in a much less forgiving place. When SKILL.md gets it wrong, Claude has
# already read the conversation and can notice the answer is nonsense. Here,
# nothing has read anything: the hook answers from the prompt text alone and
# the Claude turn never happens. A wrong yes means the user gets a confident
# answer to a question about their repo from a model that has never seen it.
#
# So the test is deliberately, almost uselessly strict, and it is a conjunction
# of four independent gates. Anything that smells of context — a pronoun, a
# path, a paste, a follow-up — fails. The cost of a false negative is zero
# (Claude answers, as it always would have); the cost of a false positive is a
# wrong answer delivered as if it were Claude's.
#
# Usage: triage.sh "<prompt>"     exit 0 = answerable with no context
#                                 exit 1 = must go to Claude (prints why)
set -uo pipefail

prompt="${1:-}"
if [ -z "$prompt" ] && [ ! -t 0 ]; then
  prompt="$(cat)"
fi
[ -n "$prompt" ] || { echo "usage: triage.sh \"<prompt>\"" >&2; exit 2; }

MAX_CHARS="${FREELOADER_TRIAGE_MAX_CHARS:-160}"

refuse() { echo "$1"; exit 1; }

# ---------------------------------------------------------------------------
# gate 1 — shape
# ---------------------------------------------------------------------------
# Anything long or multi-line is a paste, a spec, or a task. Only a one-liner
# can plausibly be a self-contained question.

[ "${#prompt}" -le "$MAX_CHARS" ] || refuse "too long (${#prompt} chars)"
case "$prompt" in
  *$'\n'*) refuse "multi-line" ;;
esac

# ---------------------------------------------------------------------------
# gate 2 — no reference to anything outside the prompt
# ---------------------------------------------------------------------------
# The giveaway for a context-dependent question is a word that points somewhere
# else: a demonstrative, a possessive, a file path, a "why did that happen".
# Every one of these is a question Claude must answer, and several of them are
# words a free model would happily answer *around* without ever noticing it was
# missing the subject.

_refs='(^| )(this|that|these|those|it|its|here|there|above|below|again|instead|mine|my|our|your|his|her|their|the (code|file|repo|project|error|bug|test|output|result|function|script|change|diff|branch|commit))( |$|[[:punct:]])'
_tasks='(^| )(fix|debug|refactor|rewrite|implement|add|remove|delete|update|change|edit|run|build|deploy|commit|push|review|check|look|find|search|open|read|write|create|make|install|migrate|rename|move|why|continue|keep going|carry on)( |$|[[:punct:]])'
_paths='(/[A-Za-z0-9_.-]+/|\.(sh|py|js|ts|tsx|jsx|go|rs|rb|java|c|cpp|h|json|ya?ml|toml|md|txt|lock|env)( |$|[[:punct:]])|~/|\$\{?[A-Z_]+|^\./)'

printf '%s' "$prompt" | grep -Eqi -- "$_refs"  && refuse "refers to conversation context"
printf '%s' "$prompt" | grep -Eqi -- "$_tasks" && refuse "asks for work, not a fact"
printf '%s' "$prompt" | grep -Eq  -- "$_paths" && refuse "names a file or path"
case "$prompt" in
  *'`'*|*'```'*) refuse "contains code" ;;
esac

# Anything addressed to Claude by name stays with Claude, always. This is also
# the user's escape hatch out of the intercept: prefixing a prompt with
# "claude," forces the normal turn.
printf '%s' "$prompt" | grep -Eqi -- '(^| )(claude|you|yourself)( |,|$)' && refuse "addressed to Claude"

# ---------------------------------------------------------------------------
# gate 3 — it has to look like a self-contained question
# ---------------------------------------------------------------------------
# An allowlist, not a blocklist: the prompt must positively match one of the
# few shapes that are answerable from general knowledge alone. Everything not
# on this list goes to Claude, which is the correct default for a list this
# short.

_lookup='^(what|whats|what.s|who|when|where|which|how)( (is|are|was|were|does|do|did|many|much|long|old|far|tall|big))?\b'
_command='^(translate|convert|define|spell|pronounce|abbreviate|capitalize|pluralize|singularize)\b'
_mathy='^[0-9(][0-9[:space:]().*/+^%-]*(=|\?)?$'
_unit='^[0-9.]+ ?[a-z°]+ (to|in|into) [a-z°]'

if ! printf '%s' "$prompt" | grep -Eqi -- "$_lookup" \
   && ! printf '%s' "$prompt" | grep -Eqi -- "$_command" \
   && ! printf '%s' "$prompt" | grep -Eq  -- "$_mathy" \
   && ! printf '%s' "$prompt" | grep -Eqi -- "$_unit"; then
  refuse "not a recognised self-contained question shape"
fi

# ---------------------------------------------------------------------------
# gate 4 — nothing sensitive
# ---------------------------------------------------------------------------
# The same guard route.sh applies, run early so the hook can bail before
# spending any time on a prompt that could never be sent anyway.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -r "$SCRIPT_DIR/scan.sh" ]; then
  # shellcheck source=scan.sh
  . "$SCRIPT_DIR/scan.sh"
  if ! findings=$(freeloader_scan_prompt "$prompt"); then
    refuse "sensitive: $(printf '%s' "$findings" | tr '\n' ' ')"
  fi
else
  refuse "scanner unavailable"
fi

exit 0
