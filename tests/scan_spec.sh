#!/usr/bin/env bash
# Specs for scripts/scan.sh — the pre-send guard.
#
# Two failure directions, weighted very differently:
#   a miss  → a credential or someone's personal data reaches a free endpoint
#   a false → one prompt gets answered by Claude, as it would have anyway
# So the "must block" examples are the load-bearing ones, and the "must not
# block" examples exist to keep the guard from being so noisy that routing
# stops happening at all.
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/spec_helper.sh"

scan() { "$PROJECT_DIR/scripts/scan.sh" "$1" 2>/dev/null; }

# blocks <text> — asserts the text is refused, and names the category.
blocks() {
  local out; out=$(scan "$1"); local st=$?
  expect_status "$st" "1" "expected '$1' to be refused"
  [ -n "$out" ] || _fail "expected a category for '$1'"
}

# passes <text> — asserts the text is routable.
passes() {
  local out; out=$(scan "$1"); local st=$?
  expect_status "$st" "0" "expected '$1' to be routable, got: $(printf '%s' "$out" | tr '\n' ' ')"
}

describe "scan.sh — credentials"

  context "with an issuer-prefixed token"

    it "blocks an Anthropic key" '
      blocks "here is my key sk-ant-api03-AbCdEfGhIjKlMnOpQrSt"'

    it "blocks a GitHub token" '
      blocks "ghp_AbCdEfGhIjKlMnOpQrStUvWxYz1234"'

    it "blocks an AWS access key id" '
      blocks "AKIAIOSFODNN7EXAMPLE is in the config"'

    it "blocks a Slack token" '
      blocks "xoxb-123456789012-abcdefghijkl"'

  context "with a key that has no recognisable prefix"

    it "blocks a private key block" '
      blocks "-----BEGIN OPENSSH PRIVATE KEY----- b3BlbnNzaC1r"'

    it "blocks a JWT" '
      blocks "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.dozjgNryP4J3jVmNHl0w5N"'

    it "blocks a bearer header" '
      blocks "Authorization: Bearer abcdefghijklmnopqrstuvwxyz123456"'

  context "with a credential assignment"

    it "blocks a password with a real-looking value" '
      blocks "password: hunter2secret"'

    it "blocks a pasted .env line" '
      blocks "DB_PASSWORD=pr0d-db-9f2a1c"'

    # Every README on earth contains these. Blocking them would teach the user
    # the guard is noise, which is how a guard stops being read.
    it "does not block a documented placeholder" '
      passes "put API_KEY=your_api_key_here in .env"
      passes "set client_secret=<your-secret> first"
      passes "API_KEY=xxxxxxxxxxxx"'

    it "does not block a shell variable reference" '
      passes "run with API_KEY=\$MY_KEY set"'

    # "secret" is an ordinary English word before it is a credential name.
    it "does not block a sentence that happens to say secret" '
      passes "the secret to good bread is patience and time"'

describe "scan.sh — personal data"

  context "with an email address"

    it "blocks a real one" '
      blocks "mail rafael.polo@gmail.com about the invoice"'

    # A regex/validation prompt is exactly the kind of cheap request this skill
    # exists to route, and it always carries a documentation address.
    it "does not block a documentation address" '
      passes "write a regex that matches user@example.com"
      passes "is admin@test.local a valid address"'

  context "with a document or account number"

    it "blocks a Brazilian CPF" '
      blocks "meu CPF é 123.456.789-09"'

    it "blocks a CNPJ" '
      blocks "CNPJ 12.345.678/0001-95"'

    it "blocks a US SSN" '
      blocks "SSN 123-45-6789"'

    it "blocks an IBAN" '
      blocks "send it to DE89 3704 0044 0532 0130 00"'

  context "with a card number"

    it "blocks a Luhn-valid card" '
      blocks "card 4111 1111 1111 1111 exp 12/29"
      blocks "4111111111111111"'

    # Luhn alone fires on roughly one in ten long digit runs, and a millisecond
    # timestamp is a long digit run — the length floor and issuer digit exist
    # to keep those routable.
    it "does not block a timestamp or an id" '
      passes "convert 1735689600000 to a date"
      passes "order 9876543210987654321 status"'

  context "with a phone number"

    it "blocks an international number" '
      blocks "call me at +55 21 98765-4321"
      blocks "reach me on +1 (202) 555-0134"'

    it "does not block arithmetic or version strings" '
      passes "what is 2+2"
      passes "the sum is 100 + 25 = 125"
      passes "python 3.11.4 vs 3.12.0 release dates"'

describe "scan.sh — ordinary cheap prompts"

  # If these ever start failing, the guard has made the skill useless: this is
  # the exact traffic it is supposed to let through.
  context "with the requests the skill exists to route"

    it "routes a factual lookup" '
      passes "what is the capital of Portugal? one word"'

    it "routes a conversion" '
      passes "convert 72 fahrenheit to celsius"'

    it "routes a translation" '
      passes "translate bom dia to japanese"'

    it "routes a snippet request" '
      passes "a bash one-liner to find files modified in the last 7 days"'

    it "routes a commit sha lookup" '
      passes "explain what git rev-parse 9d2a439abcdef123 does"'

describe "scan.sh — output discipline"

  context "when it refuses a prompt"

    # The whole point is to keep the value off the wire. Echoing it into stderr
    # (and from there the transcript and the usage log) would move the leak
    # rather than close it.
    it "names the category but never the matched value" '
      out=$(scan "password: hunter2secret" 2>&1)
      expect_contains "$out" "credential"
      expect_not_contains "$out" "hunter2secret"'

    it "reports every category it found" '
      out=$(scan "mail rafael.polo@gmail.com the key ghp_AbCdEfGhIjKlMnOpQrStUvWxYz1234")
      expect_contains "$out" "email"
      expect_contains "$out" "api-token"'

  context "with no input at all"

    it "exits 2 and explains usage" '
      out=$("$PROJECT_DIR/scripts/scan.sh" </dev/null 2>&1); status=$?
      expect_status "$status" "2"
      expect_contains "$out" "usage:"'

spec_summary
