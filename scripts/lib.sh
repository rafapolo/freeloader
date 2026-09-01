#!/usr/bin/env bash
# Shared helpers for the freeloader scripts. Source, don't execute.

FREELOADER_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FREELOADER_ROOT="$(cd "$FREELOADER_LIB_DIR/.." && pwd)"

# The pre-send guard (freeloader_scan_prompt). Sourced here rather than only by
# route.sh so that anything which grows the ability to send text to a free model
# gets the check by default instead of having to remember it.
#
# If the file is missing (a half-copied install, a partial symlink), refuse
# every prompt rather than letting an unchecked one through. Same reasoning as
# the sandbox: a broken guard has to look like a broken guard, not like a
# working one that happens to allow everything.
if [ -r "$FREELOADER_LIB_DIR/scan.sh" ]; then
  # shellcheck source=scan.sh
  . "$FREELOADER_LIB_DIR/scan.sh"
else
  freeloader_scan_prompt() { echo "scanner-unavailable"; return 1; }
fi

# ---------------------------------------------------------------------------
# timeout
# ---------------------------------------------------------------------------

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

# ---------------------------------------------------------------------------
# sandboxed opencode invocation
# ---------------------------------------------------------------------------

# An empty directory to run opencode in. `opencode run` otherwise inherits the
# caller's cwd — i.e. the user's repository — and even with tools disabled we
# don't want the free model's session rooted anywhere real. Stable path rather
# than a fresh mktemp per call, so repeated routing doesn't litter $TMPDIR.
freeloader_sandbox_dir() {
  local dir="${FREELOADER_SANDBOX:-${TMPDIR:-/tmp}/freeloader-sandbox}"
  mkdir -p "$dir" 2>/dev/null || return 1
  printf '%s' "$dir"
}

# The opencode config that defines the no-tools `freeloader` agent. Kept beside
# the scripts so this works from a checkout or a symlink, and so we never have
# to modify the user's own ~/.config/opencode/opencode.jsonc.
freeloader_agent_config() {
  printf '%s' "${FREELOADER_AGENT_CONFIG:-$FREELOADER_ROOT/agent/freeloader.json}"
}

# oc_run <timeout_secs> <model> <prompt>
#
# Runs one prompt through opencode with every hardening flag applied, and emits
# the raw JSON event stream (JSONL) on stdout. Returns opencode's exit status,
# or 124 on timeout.
#
#   --dir      : empty scratch dir, so the session is not rooted in the repo
#   --agent    : the no-tools agent from agent/freeloader.json
#   --pure     : skip external plugins (they can re-introduce tools)
#   --format   : structured events — the ONLY reliable way to tell a real answer
#                from a failure, because `opencode run` exits 0 even when the
#                stream is nothing but {"type":"error"}.
#
# opencode's own stderr is inspected (and echoed when FREELOADER_DEBUG=1) rather
# than blindly discarded, because of one specific fail-open: if --agent names an
# agent opencode cannot load, it does NOT error out. It prints
#
#   ! agent "freeloader" not found. Falling back to default agent
#
# to stderr and proceeds with the DEFAULT agent — the full-permission coding
# agent, in the sandbox dir but with every tool back. A dropped OPENCODE_CONFIG
# would therefore silently undo the entire sandbox with no visible symptom. We
# detect that line and convert the run into a hard failure, so the worst case is
# "this model is skipped" instead of "the free model got its tools back".
oc_run() {
  local secs="$1" model="$2" prompt="$3"
  # NB: `rc`, not `status` — `status` is a read-only builtin in zsh, and this
  # file is a library that may get sourced from a non-bash shell.
  local sandbox config errfile rc
  sandbox="$(freeloader_sandbox_dir)" || return 1
  config="$(freeloader_agent_config)"

  if [ ! -f "$config" ]; then
    printf '{"type":"error","error":{"name":"FreeloaderConfigMissing","data":{"message":"agent config not found at %s — refusing to run unsandboxed"}}}\n' "$config"
    return 1
  fi

  errfile=$(mktemp)
  OPENCODE_CONFIG="$config" run_with_timeout "$secs" \
    opencode run --pure --dir "$sandbox" --agent freeloader \
    --format json -m "$model" "$prompt" 2>"$errfile"
  rc=$?

  if grep -q 'agent "freeloader" not found' "$errfile" 2>/dev/null; then
    printf '{"type":"error","error":{"name":"FreeloaderAgentNotLoaded","data":{"message":"opencode fell back to the default (tool-enabled) agent — refusing the result"}}}\n'
    rc=1
  fi
  [ "${FREELOADER_DEBUG:-}" = "1" ] && cat "$errfile" >&2
  rm -f "$errfile"
  return $rc
}

# ---------------------------------------------------------------------------
# parsing opencode's JSON event stream
# ---------------------------------------------------------------------------
#
# Events are newline-delimited JSON objects. The ones that matter:
#   {"type":"text",        "part":{"text": "..."}}          <- the actual answer
#   {"type":"step_finish", "part":{"reason":"stop","tokens":{...}}}
#   {"type":"error",       "error":{"name":..,"data":{"message":..}}}
#
# `fromjson? // empty` tolerates any non-JSON line (a plugin banner, a partial
# write on timeout) instead of failing the whole parse.

# oc_text <jsonl> — the concatenated assistant text, or empty if there is none.
oc_text() {
  printf '%s' "$1" | jq -rR 'fromjson? // empty | select(.type=="text") | .part.text // empty' 2>/dev/null
}

# oc_error <jsonl> — the first error message in the stream, or empty.
oc_error() {
  printf '%s' "$1" | jq -rR 'fromjson? // empty | select(.type=="error")
    | (.error.data.message // .error.name // "unknown error")' 2>/dev/null | head -1
}

# oc_error_name <jsonl> — the first error's name, or empty. Callers use this to
# tell a MODEL failure (that model is bad; demote it and try the next one) from
# a FREELOADER failure (our sandbox didn't load; every model will fail
# identically, and none of them deserve to be demoted for it).
oc_error_name() {
  printf '%s' "$1" | jq -rR 'fromjson? // empty | select(.type=="error")
    | .error.name // empty' 2>/dev/null | head -1
}

# oc_finished <jsonl> — "true" if the stream contains a step_finish, else "false".
# A stream with text but no step_finish was cut off mid-answer; relaying that as
# a complete reply would hand the user a truncated answer as if it were whole.
oc_finished() {
  if printf '%s' "$1" | jq -rR 'fromjson? // empty | select(.type=="step_finish")' 2>/dev/null | grep -q .; then
    echo true
  else
    echo false
  fi
}

# oc_tokens <jsonl> — {"input":N,"output":N,"total":N} summed over all steps.
oc_tokens() {
  printf '%s' "$1" | jq -sR '
    [ split("\n")[] | fromjson? // empty
      | select(.type=="step_finish") | .part.tokens // empty ]
    | { input:  (map(.input  // 0) | add // 0),
        output: (map(.output // 0) | add // 0),
        total:  (map(.total  // 0) | add // 0) }' 2>/dev/null \
    || echo '{"input":0,"output":0,"total":0}'
}

# ---------------------------------------------------------------------------
# usage log
# ---------------------------------------------------------------------------

FREELOADER_USAGE_LOG_DEFAULT="$HOME/.cache/freeloader-usage.jsonl"

# Per-token rates in USD per 1M tokens for the Claude model this would
# otherwise have been spent on. Defaults to Claude Sonnet 5 ($2 in / $10 out).
# Override for a different baseline, e.g. Claude Opus 5:
#   FREELOADER_PRICE_MODEL=claude-opus-5 FREELOADER_PRICE_IN=5 FREELOADER_PRICE_OUT=25
freeloader_price_model() { printf '%s' "${FREELOADER_PRICE_MODEL:-claude-sonnet-5}"; }
freeloader_price_in()    { printf '%s' "${FREELOADER_PRICE_IN:-2.00}"; }
freeloader_price_out()   { printf '%s' "${FREELOADER_PRICE_OUT:-10.00}"; }

# Re-reading an already-cached conversation costs 0.1x the input rate. This is
# the rate that decides whether routing is worth anything at all: every route
# made from inside a Claude turn adds one more request that re-sends the whole
# conversation at this price, whether the free model answers well or not.
freeloader_price_cache_read() {
  if [ -n "${FREELOADER_PRICE_CACHE_READ:-}" ]; then
    printf '%s' "$FREELOADER_PRICE_CACHE_READ"
  else
    awk -v p="$(freeloader_price_in)" 'BEGIN { printf "%.4f", p * 0.1 }'
  fi
}

# ---------------------------------------------------------------------------
# conversation size
# ---------------------------------------------------------------------------

FREELOADER_STATE_DEFAULT="$HOME/.cache/freeloader-state.json"
freeloader_state_file() { printf '%s' "${FREELOADER_STATE:-$FREELOADER_STATE_DEFAULT}"; }

# freeloader_record_context <transcript_path>
#
# Hooks are handed the session transcript; route.sh is not. Without this number
# the cost side of a route is unmeasurable, and the project can only report its
# own upside. Stashed in the state file so route.sh can read it later.
#
# bytes/4 over the whole transcript is a proxy, and an over-estimate: it counts
# JSONL scaffolding, and a compacted conversation sends less than the transcript
# holds. Erring high is the honest direction here — it inflates the *cost* of
# routing, so the numbers never flatter the premise.
freeloader_record_context() {
  local transcript="$1" state bytes tokens prior tmp
  [ -f "$transcript" ] || return 0
  command -v jq >/dev/null 2>&1 || return 0
  state="$(freeloader_state_file)"
  bytes=$(wc -c < "$transcript" 2>/dev/null | tr -d ' ') || return 0
  [ -n "$bytes" ] || return 0
  tokens=$(( bytes / 4 ))

  mkdir -p "$(dirname "$state")" 2>/dev/null || return 0
  if [ -f "$state" ] && jq -e . "$state" >/dev/null 2>&1; then
    prior=$(cat "$state")
  else
    prior='{}'
  fi
  tmp="${state}.tmp.$$"
  printf '%s' "$prior" | jq --argjson t "$tokens" '.context_tokens = $t' > "$tmp" 2>/dev/null \
    && mv "$tmp" "$state" \
    || rm -f "$tmp"
}

# The last recorded conversation size, or 0 when no hook has run yet (in which
# case cost simply reads as 0 rather than as a guess).
freeloader_context_tokens() {
  local state; state="$(freeloader_state_file)"
  if [ -f "$state" ]; then
    jq -r '.context_tokens // 0' "$state" 2>/dev/null || printf '0'
  else
    printf '0'
  fi
}

# freeloader_log_route <json-object>
# Appends one record to the usage log. Best-effort: a failure here must never
# take down a route that otherwise succeeded.
freeloader_log_route() {
  # cap.sh calls route.sh as a sub-step and then writes one accurate record of
  # its own; without this the same work would appear on the ledger twice.
  [ "${FREELOADER_NO_LOG:-}" = "1" ] && return 0
  local log="${FREELOADER_USAGE_LOG:-$FREELOADER_USAGE_LOG_DEFAULT}"
  mkdir -p "$(dirname "$log")" 2>/dev/null || return 0
  printf '%s\n' "$1" >> "$log" 2>/dev/null || true
}
