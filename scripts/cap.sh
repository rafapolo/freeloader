#!/usr/bin/env bash
# Keeps a large command output from entering the conversation whole.
#
# MANUAL ONLY. This used to be wired to a PreToolUse hook that wrapped verbose
# Bash commands automatically. That hook was deleted: `rtk` already sits in
# exactly that slot, proxies 20+ commands (including `rtk test`, which shows
# only failures, and `rtk err`), and has saved ~504M tokens against the ~2M
# ceiling measured for this. Two PreToolUse hooks rewriting the same command is
# undefined behaviour, and the better-measured one should win.
#
# What is left for this script is the long tail rtk does not proxy — an ad-hoc
# pipeline, a one-off script, an ssh command — where you want the head, the
# failure lines and the tail instead of 40k tokens. Pipe to it deliberately:
#
# Usage:  <command> 2>&1 | cap.sh
#         cap.sh < big-file
#
# Under the threshold it is a pass-through — byte-for-byte, no model, no
# latency. Over it, stdout becomes: the head, everything that looks like a
# failure, an optional one-paragraph summary from a free model, and the tail.
#
# The full output is ALWAYS written to a file first and its path printed. The
# one unacceptable failure here is silently destroying the line that mattered,
# so nothing is ever only summarized — it is summarized *and* kept.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "$SCRIPT_DIR/lib.sh"

THRESHOLD_CHARS="${FREELOADER_CAP_THRESHOLD:-6000}"
HEAD_LINES="${FREELOADER_CAP_HEAD:-30}"
TAIL_LINES="${FREELOADER_CAP_TAIL:-30}"
MAX_ERROR_LINES="${FREELOADER_CAP_ERRORS:-40}"
SUMMARY_EXCERPT="${FREELOADER_CAP_EXCERPT:-6000}"
SUMMARY_TIMEOUT="${FREELOADER_CAP_SUMMARY_TIMEOUT:-20}"
KEEP_DIR="${FREELOADER_CAP_DIR:-${TMPDIR:-/tmp}/freeloader-output}"

# Buffered to a file rather than a shell variable, for two reasons: command
# substitution strips trailing newlines (so a pass-through would not be
# byte-exact), and a 40k-token log does not belong in a bash variable.
buf=$(mktemp "${TMPDIR:-/tmp}/freeloader-cap.XXXXXX") || { cat; exit 0; }
trap 'rm -f "$buf"' EXIT
cat > "$buf"
chars=$(wc -c < "$buf" | tr -d ' ')

# Small output: hand it back untouched. Most commands land here, and paying any
# latency or risk on them would be indefensible.
if [ "$chars" -le "$THRESHOLD_CHARS" ]; then
  cat "$buf"
  exit 0
fi

mkdir -p "$KEEP_DIR" 2>/dev/null
full="$KEEP_DIR/$(date +%Y%m%d-%H%M%S)-$$.log"
cp "$buf" "$full" 2>/dev/null || full=""

lines=$(wc -l < "$buf" | tr -d ' ')
tokens=$(( chars / 4 ))

head_part=$(head -n "$HEAD_LINES" "$buf")
tail_part=$(tail -n "$TAIL_LINES" "$buf")

# Everything that looks like it went wrong, from the middle that would
# otherwise be dropped. A summary can paraphrase a failure away; these lines
# are passed through verbatim so the exact message survives.
errors=$(grep -Ein -- '(^|[^a-z])(error|errors|failed|failure|fail|fatal|panic|traceback|exception|assertion|assert|undefined reference|cannot find|not found|refused|denied|timed out|segfault)([^a-z]|$)' "$buf" 2>/dev/null \
  | head -n "$MAX_ERROR_LINES")

# A free model summarises what no structural rule can keep.
#
# The excerpt is head + failure lines + tail, NOT the first N bytes. Feeding it
# a plain head truncation produces the worst possible artefact: a build that
# fails on its last line gets summarised, in perfect confidence, as "no
# failures were detected" — a wrong verdict printed directly above the error
# that disproves it. The failure lines are the whole reason anyone reads this
# output, so they go into the excerpt first.
#
# Bounded, short timeout, and skipped entirely if the content trips the
# credential/personal-data scan, which real build output regularly does.
summary=""
summarized=false
excerpt=$(printf '%s\n[... middle omitted ...]\n%s\n[... tail ...]\n%s\n' \
  "$head_part" "$errors" "$tail_part" | head -c "$SUMMARY_EXCERPT")
if [ -x "$SCRIPT_DIR/route.sh" ] && freeloader_scan_prompt "$excerpt" >/dev/null 2>&1; then
  summary=$(FREELOADER_NO_LOG=1 run_with_timeout "$SUMMARY_TIMEOUT" "$SCRIPT_DIR/route.sh" \
    "Below is an excerpt of a long command output: the first lines, then any lines matching failure patterns, then the last lines. Summarise in at most 3 sentences: what ran, whether it succeeded, and name any failures exactly. If failure lines are present, say it failed. No preamble.

$excerpt" 2>/dev/null)
  [ -n "${summary//[[:space:]]/}" ] && summarized=true || summary=""
fi

# ---------------------------------------------------------------------------
# assemble
# ---------------------------------------------------------------------------

printf '%s\n' "$head_part"
printf '\n[freeloader] output capped: %s lines / ~%s tokens held out of context\n' "$lines" "$tokens"
[ -n "$full" ] && printf '[freeloader] full output: %s\n' "$full"

if [ "$summarized" = true ]; then
  printf '\n[freeloader] free-model summary:\n%s\n' "$summary"
fi

if [ -n "$errors" ]; then
  printf '\n[freeloader] lines matching failure patterns (line numbers from the full output):\n%s\n' "$errors"
fi

printf '\n[freeloader] last %s lines:\n%s\n' "$TAIL_LINES" "$tail_part"

# ---------------------------------------------------------------------------
# ledger
# ---------------------------------------------------------------------------
# Counted once, at the input rate, though this is an under-estimate twice over:
# the displaced tokens would also have been re-read on every subsequent turn of
# the session, and `summarized` records honestly whether a free model did any
# of the work or the structural cap did all of it.

kept=$(( ${#head_part} + ${#tail_part} + ${#errors} + ${#summary} ))
displaced=$(( (chars - kept) / 4 ))
[ "$displaced" -lt 0 ] && displaced=0

freeloader_log_route "$(jq -cn \
  --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --arg baseline "$(freeloader_price_model)" \
  --argjson pin "$(freeloader_price_in)" \
  --argjson displaced "$displaced" \
  --argjson summarized "$summarized" \
  '{ts:$ts, ok:true, mode:"cap", model:(if $summarized then "free-model summary" else "structural cap only" end),
    summarized:$summarized,
    saved:{baseline_model:$baseline, input_tokens:$displaced, output_tokens:0,
           usd: ($displaced/1000000*$pin)},
    cost:{usd:0, extra_request_tokens:0, note:"compressed in a hook; no extra Claude turn"},
    net_usd: ($displaced/1000000*$pin)}')" 2>/dev/null

exit 0
