#!/usr/bin/env bash
# Reports live Claude subscription rate-limit usage (5h / 7d windows) by
# making one minimal Messages API call and reading the
# `anthropic-ratelimit-unified-*` response headers. These headers only show
# up on /v1/messages (not on lighter endpoints like /v1/models), so this
# necessarily spends a few real tokens (~15-20, on Haiku) each time it runs.
#
# Usage: usage.sh [--json]
#
# Credential resolution order:
#   1. $ANTHROPIC_AUTH_TOKEN / $ANTHROPIC_API_KEY, if set (portable)
#   2. macOS Keychain "Claude Code-credentials" entry (the token Claude Code
#      itself is already using) — macOS only
set -uo pipefail

JSON_OUT=false
[ "${1:-}" = "--json" ] && JSON_OUT=true

TOKEN=""
AUTH_HEADER="Authorization"
AUTH_VALUE=""

# Pull the accessToken out of the same {"claudeAiOauth": {"accessToken": ...}}
# shape Claude Code stores, given raw JSON text on stdin. Shared by every
# credential-store backend below so each just has to produce that JSON.
# `// empty` keeps a malformed/absent field from yielding the string "null".
extract_access_token() {
  jq -r '.claudeAiOauth.accessToken // empty' 2>/dev/null
}

if [ -n "${ANTHROPIC_AUTH_TOKEN:-}" ]; then
  # Portable, tested on every OS — prefer this if you have it.
  AUTH_VALUE="Bearer ${ANTHROPIC_AUTH_TOKEN}"
elif [ -n "${ANTHROPIC_API_KEY:-}" ]; then
  AUTH_HEADER="x-api-key"
  AUTH_VALUE="${ANTHROPIC_API_KEY}"
elif [ "$(uname -s)" = "Darwin" ] && command -v security >/dev/null 2>&1; then
  # macOS Keychain — tested, this is what Claude Code itself uses.
  TOKEN=$(security find-generic-password -s "Claude Code-credentials" -w 2>/dev/null | extract_access_token)
  [ -n "$TOKEN" ] && AUTH_VALUE="Bearer ${TOKEN}"
elif command -v secret-tool >/dev/null 2>&1; then
  # Linux (Debian/Arch) with a Secret Service provider (GNOME Keyring /
  # KWallet via libsecret — `apt install libsecret-tools` or
  # `pacman -S libsecret`). Best-effort: this assumes Claude Code stored its
  # credential under this same service label, which isn't verified in this
  # environment (only the macOS path above was actually tested) — if it
  # comes up empty, fall back to ANTHROPIC_AUTH_TOKEN / ANTHROPIC_API_KEY.
  TOKEN=$(secret-tool lookup service "Claude Code-credentials" 2>/dev/null | extract_access_token)
  [ -n "$TOKEN" ] && AUTH_VALUE="Bearer ${TOKEN}"
fi

if [ -z "$AUTH_VALUE" ] && [ -z "${ANTHROPIC_AUTH_TOKEN:-}${ANTHROPIC_API_KEY:-}" ]; then
  # Last resort on Linux boxes with no Secret Service daemon (headless
  # servers, minimal window managers): some Claude Code installs fall back
  # to a plain credentials file. Also unverified here — treat as a guess.
  for f in "$HOME/.claude/.credentials.json" "$HOME/.config/claude-code/.credentials.json"; do
    if [ -f "$f" ]; then
      TOKEN=$(extract_access_token < "$f")
      [ -n "$TOKEN" ] && { AUTH_VALUE="Bearer ${TOKEN}"; break; }
    fi
  done
fi

if [ -z "$AUTH_VALUE" ]; then
  echo "No credentials found. Set ANTHROPIC_AUTH_TOKEN or ANTHROPIC_API_KEY" >&2
  echo "(most reliable on Linux), or run this while logged into Claude Code" >&2
  echo "on macOS (Keychain) or Linux with a Secret Service daemon running." >&2
  exit 1
fi

HEADERS_FILE=$(mktemp)
BODY_FILE=$(mktemp)
trap 'rm -f "$HEADERS_FILE" "$BODY_FILE"' EXIT

# These two are version pins, not constants — re-check them periodically:
#  - anthropic-version: the general API version header. Changes rarely;
#    2023-06-01 has been current since launch, but confirm against
#    https://platform.claude.com/docs/en/api/versioning if requests start
#    failing for no other reason.
#  - anthropic-beta: oauth-2025-04-20 is a dated beta flag specifically for
#    OAuth bearer-token auth on /v1/messages. Beta flags like this are the
#    most likely thing here to drift (get superseded by a newer dated flag,
#    or the feature could go GA and drop the header entirely). If auth starts
#    failing only for OAuth tokens (not for ANTHROPIC_API_KEY), check here
#    first — see shared/anthropic-cli.md in the claude-api skill, or WebFetch
#    the OAuth docs, for the current value.
http_status=$(curl -sS -o "$BODY_FILE" -D "$HEADERS_FILE" -w '%{http_code}' \
  https://api.anthropic.com/v1/messages \
  -H "${AUTH_HEADER}: ${AUTH_VALUE}" \
  -H "anthropic-beta: oauth-2025-04-20" \
  -H "anthropic-version: 2023-06-01" \
  -H "content-type: application/json" \
  -d '{"model":"claude-haiku-4-5","max_tokens":8,"messages":[{"role":"user","content":"hi"}]}')

if [ "$http_status" != "200" ]; then
  echo "Request failed (HTTP $http_status). Token may be expired — reopen Claude Code / re-run \`ant auth login\`." >&2
  cat "$BODY_FILE" >&2
  exit 1
fi

get_header() {
  awk -v k="$1:" 'BEGIN{IGNORECASE=1} tolower($1)==tolower(k){sub(/\r$/,"",$2); print $2}' "$HEADERS_FILE"
}

h5_status=$(get_header "anthropic-ratelimit-unified-5h-status")
h5_util=$(get_header "anthropic-ratelimit-unified-5h-utilization")
h5_reset=$(get_header "anthropic-ratelimit-unified-5h-reset")
d7_status=$(get_header "anthropic-ratelimit-unified-7d-status")
d7_util=$(get_header "anthropic-ratelimit-unified-7d-utilization")
d7_reset=$(get_header "anthropic-ratelimit-unified-7d-reset")
claim=$(get_header "anthropic-ratelimit-unified-representative-claim")
overage=$(get_header "anthropic-ratelimit-unified-overage-status")

fmt_reset() {
  [ -z "$1" ] && return
  date -r "$1" 2>/dev/null || date -d "@$1" 2>/dev/null || echo "$1"
}

if [ "$JSON_OUT" = true ]; then
  jq -n \
    --arg h5_status "$h5_status" --argjson h5_util "${h5_util:-null}" --arg h5_reset "$h5_reset" \
    --arg d7_status "$d7_status" --argjson d7_util "${d7_util:-null}" --arg d7_reset "$d7_reset" \
    --arg claim "$claim" --arg overage "$overage" \
    '{five_hour: {status:$h5_status, utilization:$h5_util, reset:$h5_reset},
      seven_day: {status:$d7_status, utilization:$d7_util, reset:$d7_reset},
      representative_claim: $claim, overage_status: $overage}'
else
  echo "5h window : ${h5_status:-?}  ${h5_util:-?} used  (resets $(fmt_reset "$h5_reset"))"
  echo "7d window : ${d7_status:-?}  ${d7_util:-?} used  (resets $(fmt_reset "$d7_reset"))"
  echo "binding   : ${claim:-?}   overage: ${overage:-?}"
fi

# Simple threshold hint. The full auto-offload policy is a TODO — see README.
for u in "$h5_util" "$d7_util"; do
  if [ -n "$u" ] && awk -v u="$u" 'BEGIN{exit !(u+0 > 0.8)}'; then
    echo "-> utilization above 0.8 — consider routing cheap prompts through freeloader" >&2
    break
  fi
done
