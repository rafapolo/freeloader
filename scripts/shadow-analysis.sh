#!/usr/bin/env bash
# Shadow analysis: how often WOULD the intercept have fired, over real history?
#
# This is the script that got intercept-hook.sh switched off by default, and it
# is kept so the finding can be re-checked rather than taken on faith. It runs
# the real scripts/triage.sh over every prompt you have ever typed, in
# ~/.claude/projects, and reports how many it would have answered from a free
# model instead of Claude.
#
# It DECIDES ONLY — no model is ever called, nothing is sent anywhere, and the
# corpus never enters a context window. Only aggregates and a small sample are
# printed. That distinction is the entire cost difference: reading those
# transcripts into a context would run to hundreds of dollars and not fit,
# while this is CPU and a couple of minutes.
#
# Result when it was last run: 34 of 7,311 prompts (0.47%) would have been
# intercepted, and hand-checking 12 of those found 1 that was safe. Read the
# sample it prints — the hit RATE is not the finding, the hit QUALITY is.
set -uo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
S="${TMPDIR:-/tmp}/freeloader-shadow"; mkdir -p "$S"
PROMPTS="$S/prompts.txt"
TRIAGE="$PROJECT_DIR/scripts/triage.sh"

# ---------------------------------------------------------------------------
# 1. extract real user prompts
# ---------------------------------------------------------------------------
# Only genuine typed prompts: not tool results, not hook injections, not
# local-command output, not the system reminders the harness splices in.
if [ ! -s "$PROMPTS" ]; then
  find ~/.claude/projects -name '*.jsonl' -exec cat {} + 2>/dev/null \
    | jq -r '
        select(.type == "user")
        | select(.isMeta // false | not)
        | .message.content
        | if type == "string" then .
          elif type == "array" then (.[] | select(.type == "text") | .text)
          else empty end' 2>/dev/null \
    | grep -v '^<' \
    | grep -v '^\[Request interrupted' \
    | grep -v '^Caveat:' \
    | grep . \
    > "$PROMPTS"
fi

total=$(wc -l < "$PROMPTS" | tr -d ' ')
echo "corpus: $total real user prompts"
echo

# ---------------------------------------------------------------------------
# 2. run the REAL triage over each
# ---------------------------------------------------------------------------
# Gate 1 (length / single-line) is applied inline first, purely as a speed
# filter — it is the same test triage.sh applies, and it removes most prompts
# without paying for a subprocess. Anything that survives goes through the
# actual production script, so this measures the shipped behaviour rather than
# a re-implementation of it.

intercepted=0
too_long=0
declare -a samples=()
: > "$S/reasons.txt"

while IFS= read -r p; do
  if [ "${#p}" -gt 160 ] || [ "${#p}" -eq 0 ]; then
    too_long=$((too_long + 1))
    echo "too long or empty" >> "$S/reasons.txt"
    continue
  fi
  if reason=$("$TRIAGE" "$p" 2>/dev/null); then
    intercepted=$((intercepted + 1))
    [ "${#samples[@]}" -lt 12 ] && samples+=("$p")
  else
    echo "${reason:-unknown}" >> "$S/reasons.txt"
  fi
done < "$PROMPTS"

# ---------------------------------------------------------------------------
# 3. report
# ---------------------------------------------------------------------------

pct=$(awk -v a="$intercepted" -v b="$total" 'BEGIN { if (b > 0) printf "%.2f", a * 100 / b; else print "0" }')
echo "would have been intercepted: $intercepted of $total  (${pct}%)"
echo
echo "why the rest stayed with Claude:"
sed 's/:.*//' "$S/reasons.txt" | sort | uniq -c | sort -rn | head -12 | sed 's/^/  /'
echo
echo "sample of prompts that would have been answered by a free model:"
for s in "${samples[@]}"; do printf '  - %s\n' "$s"; done
echo

# Value, at the same conservative 30k-token context used for the live A/B.
awk -v n="$intercepted" 'BEGIN {
  pcache = 0.2; pout = 10.0;
  for (ctx = 30000; ctx <= 120000; ctx *= 2) {
    per = ctx/1e6*pcache + 40/1e6*pout;
    printf "  at a %6d-token conversation: $%.4f per intercept -> $%.2f over %d prompts\n", ctx, per, per*n, n;
  }
}'
echo DONE
