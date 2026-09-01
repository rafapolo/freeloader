#!/usr/bin/env bash
# Routes one prompt to the best available free opencode model and prints its
# reply on stdout. Re-benchmarks automatically if the cache is missing/stale,
# and falls through to the next-ranked free model on failure.
#
# Usage: route.sh "<prompt text>"
#        echo "<prompt text>" | route.sh
#
# On success: reply on stdout, model name used on stderr, exit 0.
# On failure (stderr, exit 1): PROMPT_CONTAINS_SENSITIVE_DATA,
# NO_FREE_MODEL_AVAILABLE, ALL_FREE_MODELS_FAILED, or
# FREELOADER_SANDBOX_UNAVAILABLE.
#
# The model runs sandboxed and tool-less — see agent/freeloader.json and
# lib.sh's oc_run for why that is not optional — and the prompt is scanned for
# credentials and personal data before it is sent at all (scan.sh).
set -uo pipefail

# shellcheck source=lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

SKILL_DIR="$FREELOADER_ROOT"
CACHE="${OPENCODE_FREE_CACHE:-$HOME/.cache/opencode-free-models.json}"
MAX_AGE_SECS="${OPENCODE_FREE_CACHE_MAX_AGE:-86400}"  # 24h
# Hard ceiling per model. By default the real per-model budget is derived from
# that model's measured benchmark latency (see below) so a model that pinged in
# 4s doesn't hold the user for a full minute before we fall through to the next
# one; set OPENCODE_FREE_RUN_TIMEOUT to pin every model to a fixed value.
RUN_TIMEOUT_SECS="${OPENCODE_FREE_RUN_TIMEOUT:-60}"
ADAPTIVE_TIMEOUT="${OPENCODE_FREE_ADAPTIVE_TIMEOUT:-true}"
# A real prompt does more work than the one-word canary, so scale the measured
# latency up generously before using it as a deadline.
LATENCY_MULTIPLIER="${OPENCODE_FREE_LATENCY_MULTIPLIER:-6}"
MIN_TIMEOUT_SECS="${OPENCODE_FREE_MIN_TIMEOUT:-20}"

# Where this route was called from — it decides the whole economics, see the
# ledger comment further down. turn (default) | hook | cap.
MODE="${FREELOADER_ROUTE_MODE:-turn}"
# For mode=cap: how many tokens of tool output were kept out of the
# conversation. Meaningless in the other modes.
DISPLACED_TOKENS="${FREELOADER_DISPLACED_TOKENS:-0}"

prompt="${1:-}"
if [ -z "$prompt" ] && [ ! -t 0 ]; then
  prompt="$(cat)"
fi
if [ -z "$prompt" ]; then
  echo "usage: route.sh \"<prompt>\"  (or pipe prompt via stdin)" >&2
  exit 2
fi

# ---------------------------------------------------------------------------
# pre-send guard
# ---------------------------------------------------------------------------
#
# Before the cache, before any benchmark, before anything touches the network:
# a prompt carrying credentials or personal data does not get sent to a free
# third-party endpoint. See scan.sh for why this is code and not an instruction.
#
# Only the matched category names are reported — never the matched text, which
# would just relocate the leak into stderr and the usage log.
if ! findings=$(freeloader_scan_prompt "$prompt"); then
  echo "PROMPT_CONTAINS_SENSITIVE_DATA: $(printf '%s' "$findings" | tr '\n' ' ')" >&2
  freeloader_log_route "$(jq -cn \
    --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --argjson categories "$(printf '%s' "$findings" | jq -Rsc 'split("\n") | map(select(length>0))')" \
    '{ts:$ts, ok:false, blocked:"sensitive", categories:$categories}')" 2>/dev/null
  exit 1
fi

# ---------------------------------------------------------------------------
# cache
# ---------------------------------------------------------------------------

cache_is_fresh() {
  [ -f "$CACHE" ] || return 1
  local now mtime age
  now=$(date +%s)
  mtime=$(stat -f %m "$CACHE" 2>/dev/null || stat -c %Y "$CACHE" 2>/dev/null || echo 0)
  age=$(( now - mtime ))
  [ "$age" -lt "$MAX_AGE_SECS" ]
}

# Demote a model that failed on a *real* prompt, so the next call doesn't put it
# back at rank 1 and pay its full timeout again. Without this a model that
# benchmarks ok but fails in practice costs every subsequent prompt up to
# RUN_TIMEOUT_SECS of dead wait for the rest of the 24h cache window.
#
# Written via a temp file + mv so a concurrent reader never sees a partial cache.
demote_model() {
  local model="$1" reason="$2" tmp
  [ -f "$CACHE" ] || return 0
  tmp="${CACHE}.tmp.$$"
  jq --arg m "$model" --arg r "$reason" --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '
    map(if .model == $m
        then .ok = false
           | .demoted_at = $at
           | .demote_reason = $r
           | .fail_count = ((.fail_count // 0) + 1)
        else . end)' "$CACHE" > "$tmp" 2>/dev/null \
    && mv "$tmp" "$CACHE" \
    || rm -f "$tmp"
}

read_candidates() {
  # Tab-separated "<model>\t<latency_ms>", already ranked by benchmark.sh.
  candidates=()
  [ -f "$CACHE" ] || return 0
  while IFS= read -r line; do
    [ -n "$line" ] && candidates+=("$line")
  done < <(jq -r '.[] | select(.ok==true) | "\(.model)\t\(.latency_ms)"' "$CACHE" 2>/dev/null)
}

if ! cache_is_fresh; then
  "$SKILL_DIR/scripts/benchmark.sh" >/dev/null 2>&1
fi

read_candidates

# Every candidate may have been demoted by earlier routes within the same 24h
# window. The cache is "fresh" by mtime but useless in practice — re-benchmark
# once (and only once) rather than reporting no free models when the real
# situation is just a stale ranking.
if [ "${#candidates[@]}" -eq 0 ] && [ -f "$CACHE" ]; then
  "$SKILL_DIR/scripts/benchmark.sh" >/dev/null 2>&1
  read_candidates
fi

if [ "${#candidates[@]}" -eq 0 ]; then
  echo "NO_FREE_MODEL_AVAILABLE" >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# route
# ---------------------------------------------------------------------------

started=$(date +%s%N)
attempts=()

for entry in "${candidates[@]}"; do
  m="${entry%%$'\t'*}"
  latency_ms="${entry##*$'\t'}"

  budget="$RUN_TIMEOUT_SECS"
  if [ "$ADAPTIVE_TIMEOUT" = "true" ] && [ "$latency_ms" -gt 0 ] 2>/dev/null; then
    scaled=$(( (latency_ms * LATENCY_MULTIPLIER + 999) / 1000 ))
    [ "$scaled" -lt "$MIN_TIMEOUT_SECS" ] && scaled="$MIN_TIMEOUT_SECS"
    [ "$scaled" -gt "$RUN_TIMEOUT_SECS" ] && scaled="$RUN_TIMEOUT_SECS"
    budget="$scaled"
  fi

  stream=$(oc_run "$budget" "$m" "$prompt")
  status=$?

  # `opencode run` exits 0 even when the whole stream is an error event, so exit
  # status alone is not a success signal. A reply counts only if: the process
  # didn't time out, no error event was emitted, the run reached a step_finish
  # (not cut off mid-answer), and there is actual text to relay.
  reason=""
  if [ $status -eq 124 ]; then
    reason="timeout"
  else
    err=$(oc_error "$stream")
    # Our own sandbox failing is not this model's fault, and every other
    # candidate would fail the same way. Demoting the whole cache for it would
    # poison a perfectly good ranking and force a pointless re-benchmark, so
    # bail out of the loop entirely instead of walking the list.
    case "$(oc_error_name "$stream")" in
      FreeloaderConfigMissing|FreeloaderAgentNotLoaded)
        echo "FREELOADER_SANDBOX_UNAVAILABLE: $err" >&2
        exit 1 ;;
    esac
    if [ -n "$err" ]; then
      reason="error: $err"
    elif [ "$(oc_finished "$stream")" != "true" ]; then
      reason="incomplete (no step_finish)"
    fi
  fi

  reply=""
  if [ -z "$reason" ]; then
    reply=$(oc_text "$stream")
    [ -z "${reply//[[:space:]]/}" ] && reason="empty reply"
  fi

  if [ -z "$reason" ]; then
    tokens=$(oc_tokens "$stream")
    elapsed_ms=$(( ($(date +%s%N) - started) / 1000000 ))

    # Both sides of the ledger, at ~4 chars/token.
    #
    # Which side a route lands on depends entirely on WHERE it was called from,
    # and the difference is not marginal:
    #
    #   mode=turn — Claude called route.sh mid-conversation. Saved: the tokens
    #     it would have spent answering. Cost: one extra request that re-sends
    #     the entire conversation (cache-read rate), plus the reply arriving as
    #     input. On a short answer the cost is routinely the larger number, and
    #     the log has to be able to say so.
    #
    #   mode=hook — the prompt was answered in a UserPromptSubmit hook and the
    #     Claude turn never happened. Saved: that whole turn — the context read
    #     plus the output. Cost: nothing; there is no extra request to pay for.
    #
    #   mode=cap  — a large tool output was compressed before entering the
    #     conversation. Saved: the tokens that never entered context (counted
    #     once, though they would have been re-read on every later turn too).
    freeloader_log_route "$(jq -cn \
      --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
      --arg model "$m" \
      --arg mode "$MODE" \
      --arg baseline "$(freeloader_price_model)" \
      --argjson pin "$(freeloader_price_in)" \
      --argjson pout "$(freeloader_price_out)" \
      --argjson pcache "$(freeloader_price_cache_read)" \
      --argjson ctx "$(freeloader_context_tokens)" \
      --argjson displaced "$DISPLACED_TOKENS" \
      --argjson prompt_chars "${#prompt}" \
      --argjson reply_chars "${#reply}" \
      --argjson free_tokens "$tokens" \
      --argjson elapsed_ms "$elapsed_ms" \
      --argjson attempts "$(printf '%s\n' "${attempts[@]:-}" | jq -Rsc 'split("\n") | map(select(length>0))')" \
      '((($prompt_chars + 3) / 4) | floor) as $in
       | ((($reply_chars + 3) / 4) | floor) as $out
       | (if $mode == "hook" then
            {input_tokens: $ctx, output_tokens: $out,
             usd: (($ctx/1000000*$pcache) + ($out/1000000*$pout))}
          elif $mode == "cap" then
            {input_tokens: $displaced, output_tokens: 0,
             usd: ($displaced/1000000*$pin)}
          else
            {input_tokens: $in, output_tokens: $out,
             usd: (($in/1000000*$pin) + ($out/1000000*$pout))}
          end) as $saved
       | (if $mode == "turn" then
            {usd: (($ctx/1000000*$pcache) + ($out/1000000*$pin)),
             extra_request_tokens: $ctx,
             note: "one extra request re-sending the conversation, plus the reply as input"}
          else
            {usd: 0, extra_request_tokens: 0,
             note: "no extra Claude turn was needed"}
          end) as $cost
       | {ts:$ts, ok:true, mode:$mode, model:$model, elapsed_ms:$elapsed_ms,
          failed_first:$attempts,
          free_tokens:$free_tokens,
          saved: ($saved + {baseline_model:$baseline}),
          cost: $cost,
          net_usd: ($saved.usd - $cost.usd)}')" 2>/dev/null

    printf '%s\n' "$reply"
    echo "[routed via $m]" >&2
    exit 0
  fi

  attempts+=("$m: $reason")
  demote_model "$m" "$reason"
  [ "${FREELOADER_DEBUG:-}" = "1" ] && echo "[freeloader] $m failed — $reason" >&2
done

# A route that failed still cost an extra request in turn mode — the whole
# conversation was re-sent to reach a model that then didn't answer, and Claude
# answers anyway. Recording it as a plain failure with no cost would hide the
# most expensive outcome the skill has.
freeloader_log_route "$(jq -cn \
  --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --arg mode "$MODE" \
  --argjson pcache "$(freeloader_price_cache_read)" \
  --argjson ctx "$(freeloader_context_tokens)" \
  --argjson attempts "$(printf '%s\n' "${attempts[@]:-}" | jq -Rsc 'split("\n") | map(select(length>0))')" \
  '(if $mode == "turn" then ($ctx/1000000*$pcache) else 0 end) as $c
   | {ts:$ts, ok:false, mode:$mode, failed:$attempts,
      cost:{usd:$c, extra_request_tokens:(if $mode == "turn" then $ctx else 0 end),
            note:"the conversation was re-sent to reach a model that did not answer"},
      net_usd: (0 - $c)}')" 2>/dev/null

echo "ALL_FREE_MODELS_FAILED" >&2
exit 1
