#!/usr/bin/env bash
# The last check before a prompt leaves this machine.
#
# The sandbox (agent/freeloader.json) stops a free model going and *fetching*
# anything. It does nothing about what we hand it: the prompt text itself is
# posted to a third-party API on a free tier, where retention and training
# policy are not ours to set. Up to now "never route private data" lived only as
# a paragraph of instructions in SKILL.md — i.e. it depended on the model
# noticing, every single time, on every prompt, forever. That is the same
# fail-open the sandbox and the conserve-mode hook were both written to remove:
# one distracted turn and the rule is silently gone, with nothing to notice.
#
# So it is enforced here instead. route.sh refuses to send a prompt that trips
# any pattern below, before any network call happens.
#
# Deliberately biased toward false positives. A false positive costs one prompt
# answered by Claude — the exact thing that would have happened anyway if the
# skill weren't installed. A false negative posts someone's credential or
# personal data to a free endpoint and cannot be taken back. There is no
# override env var for that reason.
#
# It is a net, not a proof. It catches structured, recognisable things
# (credentials, emails, card and document numbers). It cannot recognise a name,
# a medical detail, or "my landlord is threatening to evict me" — the judgment
# rule in SKILL.md still has to cover those. This removes the class of leak that
# a regex *can* catch, which is most of the ones that actually matter.
#
# Usage (CLI):
#   scan.sh "<text>"     # prints matched categories, one per line
#                        # exit 0 = clean, 1 = must not be routed, 2 = usage
# Usage (library):
#   . scan.sh
#   freeloader_scan_prompt "$text" || refuse

# ---------------------------------------------------------------------------
# patterns
# ---------------------------------------------------------------------------
# ERE only (no \d, no \b, no lookaround): BSD grep on a stock macOS has no -P,
# and these have to behave identically there and on GNU grep.

_FL_Q="[\"']"

# Credentials with a recognisable issuer prefix. Near-zero false positive rate:
# nothing else looks like this.
_FL_P_PRIVATE_KEY='-----BEGIN [A-Z ]*PRIVATE KEY-----'
_FL_P_TOKEN='(sk-ant-[A-Za-z0-9_-]{8}|sk-[A-Za-z0-9]{20}|gh[pousr]_[A-Za-z0-9]{20}|github_pat_[A-Za-z0-9_]{20}|xox[abprs]-[A-Za-z0-9-]{10}|AIza[A-Za-z0-9_-]{20}|(AKIA|ASIA)[0-9A-Z]{16}|glpat-[A-Za-z0-9_-]{16}|npm_[A-Za-z0-9]{20}|hf_[A-Za-z0-9]{20})'
_FL_P_JWT='eyJ[A-Za-z0-9_=-]{10,}\.[A-Za-z0-9_=-]{10,}\.[A-Za-z0-9_=.+/-]{10,}'
_FL_P_BEARER='[Bb]earer[[:space:]]+[A-Za-z0-9._~+/=-]{20,}'

# `password: hunter2`, `API_KEY=abc123...`, a pasted .env line. Broader, so it
# gets two rounds of filtering below (placeholder values out, token-shaped
# values in) before it counts as a hit.
_FL_P_ASSIGN="(password|passwd|pwd|secret|api[_-]?key|apikey|access[_-]?token|auth[_-]?token|client[_-]?secret|credentials?)${_FL_Q}?[[:space:]]*[:=][[:space:]]*${_FL_Q}?[^[:space:]]{6,}"

# Documentation and boilerplate are full of fake credentials. Blocking on those
# would train the user to distrust the guard, which is worse than not having it.
_FL_P_PLACEHOLDER="(your|my|our|some|the)[_-]?(api|secret|token|key|pass)|xxx|changeme|change_me|placeholder|redacted|dummy|fake|sample|example|<[^>]*>|\\\$[A-Za-z_{]|\\.\\.\\.|\\*\\*\\*"

# A real secret looks like a token, not like a word: it has a digit, an
# underscore or a hyphen in it. `secret: patience and time` is a sentence;
# `secret: s3cr3t-value` is a credential.
_FL_P_TOKENISH="[:=][[:space:]]*${_FL_Q}?[^[:space:]]*[0-9_-]"

# Personal data.
_FL_P_EMAIL='[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}'
_FL_P_EMAIL_PLACEHOLDER='@(example|test|sample|domain|yourdomain|mydomain|acme|foo|bar|baz|company|localhost)\.'
# BR CPF, BR CNPJ, US SSN. Punctuated forms only — bare 11-digit runs are
# indistinguishable from any other number and would fire on timestamps and ids.
_FL_P_NATIONAL_ID='([0-9]{3}\.[0-9]{3}\.[0-9]{3}-[0-9]{2}|[0-9]{2}\.[0-9]{3}\.[0-9]{3}/[0-9]{4}-[0-9]{2}|[0-9]{3}-[0-9]{2}-[0-9]{4})'
# Requires the leading +. Without it, every version string and id becomes a
# phone number. Groups are 2-5 digits so a Brazilian mobile (+55 21 98765-4321)
# is caught as readily as a US one.
_FL_P_PHONE='\+[0-9]{1,3}[[:space:]().-]{0,2}[0-9]{2,5}([[:space:]().-]{0,2}[0-9]{2,5}){1,3}'
_FL_P_IBAN='(^|[^A-Za-z0-9])[A-Z]{2}[0-9]{2}[[:space:]]?[A-Z0-9]{4}([[:space:]]?[A-Z0-9]{4}){2,}'

# ---------------------------------------------------------------------------
# matchers
# ---------------------------------------------------------------------------

_fl_match() { # <text> <ere>
  printf '%s' "$1" | grep -Eq -- "$2" 2>/dev/null
}

# An assignment counts only if it survives both filters: not a documented
# placeholder, and token-shaped rather than a word.
_fl_match_assignment() { # <text>
  printf '%s' "$1" \
    | grep -Eio -- "$_FL_P_ASSIGN" 2>/dev/null \
    | grep -Eiv -- "$_FL_P_PLACEHOLDER" 2>/dev/null \
    | grep -Eqi -- "$_FL_P_TOKENISH" 2>/dev/null
}

# Any email that isn't on a documentation domain. `user@example.com` in a
# "write me a regex" prompt is not personal data; a real address is.
_fl_match_email() { # <text>
  printf '%s' "$1" \
    | grep -Eo -- "$_FL_P_EMAIL" 2>/dev/null \
    | grep -Eqiv -- "$_FL_P_EMAIL_PLACEHOLDER" 2>/dev/null
}

# Luhn-valid, 14-19 digits, starting with a real card issuer digit (3-6).
# Luhn alone would fire on ~1 in 10 long digit runs, and a 13-digit millisecond
# timestamp is a long digit run — hence the length floor and the issuer check.
_fl_match_card() { # <text>
  printf '%s' "$1" \
    | grep -Eo -- '[0-9][0-9 -]{12,22}[0-9]' 2>/dev/null \
    | awk '
      {
        gsub(/[ -]/, "", $0)
        n = length($0)
        if (n < 14 || n > 19) next
        if ($0 !~ /^[3-6]/) next
        sum = 0; dbl = 0
        for (i = n; i >= 1; i--) {
          d = substr($0, i, 1) + 0
          if (dbl) { d *= 2; if (d > 9) d -= 9 }
          sum += d
          dbl = !dbl
        }
        if (sum % 10 == 0) { hit = 1; exit }
      }
      END { exit !hit }' 2>/dev/null
}

# ---------------------------------------------------------------------------
# freeloader_scan_prompt <text>
#
# Prints one category name per finding on stdout.
# Returns 0 when the text is clean (safe to route), 1 when it must not leave
# the machine. Never prints the matched value — that would just move the leak
# into stderr, the transcript and the usage log.
# ---------------------------------------------------------------------------
freeloader_scan_prompt() {
  local text="$1" found=0

  _fl_match "$text" "$_FL_P_PRIVATE_KEY"  && { echo "private-key";  found=1; }
  _fl_match "$text" "$_FL_P_TOKEN"        && { echo "api-token";    found=1; }
  _fl_match "$text" "$_FL_P_JWT"          && { echo "jwt";          found=1; }
  _fl_match "$text" "$_FL_P_BEARER"       && { echo "bearer-token"; found=1; }
  _fl_match_assignment "$text"            && { echo "credential";   found=1; }
  _fl_match_email "$text"                 && { echo "email";        found=1; }
  _fl_match "$text" "$_FL_P_NATIONAL_ID"  && { echo "national-id";  found=1; }
  _fl_match_card "$text"                  && { echo "card-number";  found=1; }
  _fl_match "$text" "$_FL_P_PHONE"        && { echo "phone";        found=1; }
  _fl_match "$text" "$_FL_P_IBAN"         && { echo "iban";         found=1; }

  [ "$found" -eq 0 ]
}

# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  set -uo pipefail
  _fl_input="${1:-}"
  if [ -z "$_fl_input" ] && [ ! -t 0 ]; then
    _fl_input="$(cat)"
  fi
  if [ -z "$_fl_input" ]; then
    echo "usage: scan.sh \"<text>\"  (or pipe text via stdin)" >&2
    exit 2
  fi
  freeloader_scan_prompt "$_fl_input"
fi
