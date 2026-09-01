#!/usr/bin/env bash
# Reports what freeloader has actually saved, from the usage log route.sh writes.
#
# Usage: stats.sh [--json] [--since <ISO8601>]
#
# Every successful route appends one record to ~/.cache/freeloader-usage.jsonl
# (FREELOADER_USAGE_LOG). Without this the project's entire premise -- "$0
# instead of Claude tokens" -- is an unmeasured claim.
#
# The dollar figure is a deliberate UNDER-estimate. It prices only the prompt
# and the reply at ~4 chars/token; answering in-conversation would additionally
# have re-sent the surrounding context as input tokens on every turn, which is
# not counted here.
set -uo pipefail

# shellcheck source=lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

LOG="${FREELOADER_USAGE_LOG:-$FREELOADER_USAGE_LOG_DEFAULT}"
JSON_OUT=false
SINCE=""

while [ $# -gt 0 ]; do
  case "$1" in
    --json)  JSON_OUT=true; shift ;;
    --since) SINCE="${2:-}"; shift 2 ;;
    -h|--help)
      grep '^# ' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
      exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

if ! command -v jq >/dev/null 2>&1; then
  echo '{"error":"jq not found on PATH"}' >&2
  exit 1
fi

if [ ! -s "$LOG" ]; then
  if [ "$JSON_OUT" = true ]; then
    echo '{"routes":0,"note":"no usage log yet"}'
  else
    echo "No routes logged yet ($LOG)."
    echo "Run scripts/route.sh on a cheap prompt and this will start filling in."
  fi
  exit 0
fi

summary=$(jq -sR --arg since "$SINCE" '
  # Summing floats accumulates representation error (0.0022+0.0022+0.0011 comes
  # out as 0.0055000000000000005). Round at the source so the JSON consumers see
  # is clean too, not just the human output.
  def usd: (. * 1000000 | round) / 1000000;

  [ split("\n")[] | select(length > 0) | fromjson? // empty
    | select($since == "" or .ts >= $since) ] as $all
  | ($all | map(select(.ok == true)))  as $ok
  | ($all | map(select(.ok != true)))  as $failed
  | {
      routes_total:   ($all    | length),
      routes_ok:      ($ok     | length),
      routes_failed:  ($failed | length),
      first_ts:       ($all | map(.ts) | min),
      last_ts:        ($all | map(.ts) | max),
      baseline_model: ($ok | map(.saved.baseline_model) | last),
      saved: {
        input_tokens:  ($ok | map(.saved.input_tokens  // 0) | add // 0),
        output_tokens: ($ok | map(.saved.output_tokens // 0) | add // 0),
        usd:           ($ok | map(.saved.usd // 0) | add // 0 | usd)
      },
      # What routing itself cost. A route made from inside a Claude turn adds
      # one more request that re-sends the whole conversation, and a route that
      # then fails costs that with nothing to show for it. Reporting only the
      # saved side is how a skill talks you into believing a premise it fails.
      cost: {
        usd:            ($all | map(.cost.usd // 0) | add // 0 | usd),
        extra_requests: ($all | map(select((.cost.extra_request_tokens // 0) > 0)) | length)
      },
      net_usd: (($all | map(.net_usd // (.saved.usd // 0)) | add // 0) | usd),
      by_mode: ( $all | group_by(.mode // "turn")
                 | map({ mode: (.[0].mode // "turn"),
                         routes: length,
                         net_usd: (map(.net_usd // 0) | add // 0 | usd) })
                 | sort_by(-.routes) ),
      free_tokens_spent: ($ok | map(.free_tokens.total // 0) | add // 0),
      median_ms: ( ($ok | map(.elapsed_ms // 0) | sort) as $s
                   | if ($s | length) == 0 then 0 else $s[($s | length / 2 | floor)] end ),
      by_model: ( $ok | group_by(.model)
                  | map({ model: .[0].model,
                          routes: length,
                          usd: (map(.saved.usd // 0) | add // 0 | usd) })
                  | sort_by(-.routes) ),
      # Models that answered but then failed on a later prompt. A model showing
      # up here a lot benchmarks better than it performs.
      demotions: ( $all | map(.failed_first // .failed // []) | add // []
                   | map(split(":")[0]) | group_by(.)
                   | map({model: .[0], failures: length})
                   | sort_by(-.failures) )
    }' "$LOG")

if [ "$JSON_OUT" = true ]; then
  printf '%s\n' "$summary" | jq -c .
  exit 0
fi

printf '%s' "$summary" | jq -r --arg log "$LOG" '
  def money: . * 10000 | round / 10000 | tostring;
  def pad(n): (. + (" " * 40))[0:n];

  "freeloader — routed \(.routes_ok) of \(.routes_total) prompts to a free model",
  (if .first_ts then "  \(.first_ts[0:10]) → \(.last_ts[0:10])" else "" end),
  "",
  "  saved      ~\(.saved.input_tokens + .saved.output_tokens) Claude tokens" +
    "  ≈ $\(.saved.usd | money) at \(.baseline_model // "?") rates",
  "  cost       $\(.cost.usd | money) — \(.cost.extra_requests) extra request(s) re-sending the conversation",
  (if .net_usd < 0 then
     "  net        -$\((.net_usd | fabs) | money)  ← routing is costing more than it saves"
   else
     "  net        $\(.net_usd | money)"
   end),
  "  free tier  \(.free_tokens_spent) tokens spent instead ($0)",
  "  median     \(.median_ms)ms per routed prompt",
  (if .routes_failed > 0 then "  fell back  \(.routes_failed) prompt(s) — Claude answered those" else empty end),
  "",
  "  by mode",
  (.by_mode[] | "    " + (.mode | pad(46)) + "\(.routes) route(s)   net " +
     (if .net_usd < 0 then "-$\((.net_usd | fabs) | money)" else "$\(.net_usd | money)" end)),
  "",
  "  by model",
  (.by_model[] | "    " + (.model | pad(46)) + "\(.routes) route(s)   $\(.usd | money)"),
  (if (.demotions | length) > 0 then
     "", "  demoted mid-session (benchmarked ok, failed on a real prompt)",
     (.demotions[] | "    " + (.model | pad(46)) + "\(.failures) failure(s)")
   else empty end),
  "",
  "  log: \($log)"
'
