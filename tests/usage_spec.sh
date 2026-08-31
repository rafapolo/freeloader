#!/usr/bin/env bash
# Specs for scripts/usage.sh — credential precedence, header parsing, and the
# hard requirement that a credential is never printed.
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/spec_helper.sh"

SECRET="sk-ant-oat01-SUPERSECRET-must-never-appear-in-output"

# usage_with  <behaviour> [env...] — run usage.sh with stubbed curl/security.
# usage_json  <behaviour> [env...] — same, but with --json.
# Behaviours: ok | warning | http401 | noheaders
usage_with() { _run_usage "$1" "" "${@:2}"; }
usage_json()  { _run_usage "$1" "--json" "${@:2}"; }

_run_usage() {
  local behaviour="$1" flag="$2"; shift 2
  (
    with_stub_path
    stub_bin curl <<STUB
#!/usr/bin/env bash
# Parse out the -D <headers file> and -o <body file> arguments.
hdr=""; body=""
while [ \$# -gt 0 ]; do
  case "\$1" in
    -D) hdr="\$2"; shift 2 ;;
    -o) body="\$2"; shift 2 ;;
    *)  shift ;;
  esac
done
# Record everything the caller passed, so a spec can assert the token was sent
# but never printed.
case "$behaviour" in
  http401)
    printf 'HTTP/2 401\r\n' > "\$hdr"
    echo '{"error":"unauthorized"}' > "\$body"
    printf '401'
    ;;
  noheaders)
    printf 'HTTP/2 200\r\n' > "\$hdr"
    echo '{"usage":{}}' > "\$body"
    printf '200'
    ;;
  warning)
    { printf 'HTTP/2 200\r\n'
      printf 'anthropic-ratelimit-unified-5h-status: allowed_warning\r\n'
      printf 'anthropic-ratelimit-unified-5h-utilization: 0.92\r\n'
      printf 'anthropic-ratelimit-unified-5h-reset: 1788172800\r\n'
      printf 'anthropic-ratelimit-unified-7d-status: allowed\r\n'
      printf 'anthropic-ratelimit-unified-7d-utilization: 0.27\r\n'
      printf 'anthropic-ratelimit-unified-7d-reset: 1788649200\r\n'
      printf 'anthropic-ratelimit-unified-representative-claim: five_hour\r\n'
      printf 'anthropic-ratelimit-unified-overage-status: rejected\r\n'
    } > "\$hdr"
    echo '{"content":[{"type":"text","text":"hi"}]}' > "\$body"
    printf '200'
    ;;
  *)
    { printf 'HTTP/2 200\r\n'
      printf 'anthropic-ratelimit-unified-5h-status: allowed\r\n'
      printf 'anthropic-ratelimit-unified-5h-utilization: 0.31\r\n'
      printf 'anthropic-ratelimit-unified-5h-reset: 1788172800\r\n'
      printf 'anthropic-ratelimit-unified-7d-status: allowed\r\n'
      printf 'anthropic-ratelimit-unified-7d-utilization: 0.12\r\n'
      printf 'anthropic-ratelimit-unified-7d-reset: 1788649200\r\n'
      printf 'anthropic-ratelimit-unified-representative-claim: five_hour\r\n'
      printf 'anthropic-ratelimit-unified-overage-status: rejected\r\n'
    } > "\$hdr"
    echo '{"content":[{"type":"text","text":"hi"}]}' > "\$body"
    printf '200'
    ;;
esac
STUB
    # Never let a spec reach the real Keychain.
    stub_bin security <<'STUB'
#!/usr/bin/env bash
exit 1
STUB
    if [ -n "$flag" ]; then
      env "$@" "$PROJECT_DIR/scripts/usage.sh" "$flag" 2>&1
    else
      env "$@" "$PROJECT_DIR/scripts/usage.sh" 2>&1
    fi
  )
}

describe "usage.sh — reporting"

  context "with a healthy account"

    it "reports both windows" '
      out=$(usage_with ok ANTHROPIC_AUTH_TOKEN="$SECRET")
      expect_contains "$out" "5h window"
      expect_contains "$out" "7d window"'

    it "shows the utilisation figures from the headers" '
      out=$(usage_with ok ANTHROPIC_AUTH_TOKEN="$SECRET")
      expect_contains "$out" "0.31"
      expect_contains "$out" "0.12"'

    it "renders the reset timestamps as dates, not epochs" '
      out=$(usage_with ok ANTHROPIC_AUTH_TOKEN="$SECRET")
      expect_not_contains "$out" "1788172800" "epoch should be humanised"'

    it "stays quiet about conserving while under the threshold" '
      out=$(usage_with ok ANTHROPIC_AUTH_TOKEN="$SECRET")
      expect_not_contains "$out" "consider routing"'

  context "with utilisation above the threshold"

    it "surfaces the allowed_warning status the API returns" '
      out=$(usage_with warning ANTHROPIC_AUTH_TOKEN="$SECRET")
      expect_contains "$out" "allowed_warning"'

    it "hints that cheap prompts should be offloaded" '
      out=$(usage_with warning ANTHROPIC_AUTH_TOKEN="$SECRET")
      expect_contains "$out" "consider routing cheap prompts through freeloader"'

  context "as machine-readable output"

    it "emits valid JSON with --json" '
      out=$(usage_json ok ANTHROPIC_AUTH_TOKEN="$SECRET")
      printf "%s" "$out" | jq -e . >/dev/null 2>&1
      expect_status "$?" "0" "expected parseable JSON"'

    it "carries both windows utilisation in the JSON" '
      out=$(usage_json ok ANTHROPIC_AUTH_TOKEN="$SECRET")
      expect_eq "$(printf "%s" "$out" | jq -r .five_hour.utilization)" "0.31"
      expect_eq "$(printf "%s" "$out" | jq -r .seven_day.utilization)" "0.12"'

    it "keeps the credential out of the JSON output too" '
      out=$(usage_json ok ANTHROPIC_AUTH_TOKEN="$SECRET")
      expect_not_contains "$out" "$SECRET" "CREDENTIAL LEAKED"'

describe "usage.sh — credential handling"

  context "the golden rule"

    it "never prints the credential on stdout or stderr" '
      out=$(usage_with ok ANTHROPIC_AUTH_TOKEN="$SECRET")
      expect_not_contains "$out" "$SECRET" "CREDENTIAL LEAKED"'

    it "does not leak it on the failure path either" '
      out=$(usage_with http401 ANTHROPIC_AUTH_TOKEN="$SECRET")
      expect_not_contains "$out" "$SECRET" "CREDENTIAL LEAKED"'

  context "when no credential is available anywhere"

    it "exits non-zero rather than making a doomed call" '
      out=$(usage_with ok ANTHROPIC_AUTH_TOKEN="" ANTHROPIC_API_KEY="" HOME="/nonexistent"); status=$?
      expect_status "$status" "1"'

    it "explains how to supply one" '
      out=$(usage_with ok ANTHROPIC_AUTH_TOKEN="" ANTHROPIC_API_KEY="" HOME="/nonexistent")
      expect_contains "$out" "ANTHROPIC_AUTH_TOKEN"'

describe "usage.sh — API failure"

  context "when the token is rejected"

    it "exits non-zero" '
      usage_with http401 ANTHROPIC_AUTH_TOKEN="$SECRET" >/dev/null 2>&1; status=$?
      expect_status "$status" "1"'

    it "tells the user the token may have expired" '
      out=$(usage_with http401 ANTHROPIC_AUTH_TOKEN="$SECRET")
      expect_contains "$out" "expired"'

spec_summary
