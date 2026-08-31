#!/usr/bin/env bash
# Live end-to-end specs. Skipped unless INTEGRATION=1, because these hit the
# real opencode CLI and the real Anthropic API — they cost real time and a
# handful of real tokens. Everything else in tests/ is hermetic.
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/spec_helper.sh"

SCRATCH="$(mktemp -d)"
trap 'rm -rf "$SCRATCH"' EXIT

describe "integration — discovery against the real opencode catalogue"

  context "with the opencode CLI installed"

    it "finds at least one genuinely free model" '
      if ! command -v opencode >/dev/null 2>&1; then
        _fail "opencode CLI not installed"
      else
        out=$(OPENCODE_FREE_CACHE="$SCRATCH/cache.json" "$PROJECT_DIR/scripts/benchmark.sh" 2>/dev/null)
        n=$(printf "%s" "$out" | jq "length")
        expect_gt "$n" "0"
      fi'

    it "ranks at least one of them as working" '
      if [ -f "$SCRATCH/cache.json" ]; then
        n=$(jq "[.[] | select(.ok)] | length" "$SCRATCH/cache.json")
        expect_gt "$n" "0"
      else
        _fail "no cache produced by the previous example"
      fi'

describe "integration — routing a real prompt"

  context "with a working free model"

    it "returns an answer from a free model" '
      if [ ! -f "$SCRATCH/cache.json" ]; then
        _fail "no benchmark cache available"
      else
        out=$(OPENCODE_FREE_CACHE="$SCRATCH/cache.json" OPENCODE_FREE_CACHE_MAX_AGE=99999 \
              "$PROJECT_DIR/scripts/route.sh" "What is 7 times 6? Reply with only the number." 2>/dev/null)
        expect_contains "$out" "42"
      fi'

describe "integration — the sandbox actually holds"

  # These are the specs that keep SKILL.md's privacy promise honest. They must
  # run against the real opencode CLI: the guarantee is a property of how
  # opencode resolves agent config, not of anything a stub can demonstrate.

  context "the agent opencode actually loads"

    it "has no tools at all" '
      if ! command -v opencode >/dev/null 2>&1; then
        _fail "opencode CLI not installed"
      else
        . "$PROJECT_DIR/scripts/lib.sh"
        stream=$(oc_run 60 "$(jq -r "[.[] | select(.ok)][0].model" "$SCRATCH/cache.json")" \
          "List every tool you have available by name. If you have none, reply exactly: NONE")
        reply=$(oc_text "$stream")
        expect_contains "$reply" "NONE" "the free model reported tools it should not have"
      fi'

    it "cannot read a file out of the working directory" '
      if ! command -v opencode >/dev/null 2>&1; then
        _fail "opencode CLI not installed"
      else
        . "$PROJECT_DIR/scripts/lib.sh"
        stream=$(oc_run 60 "$(jq -r "[.[] | select(.ok)][0].model" "$SCRATCH/cache.json")" \
          "Read the file README.md and reply with its first word, or NO_FILE_ACCESS if you cannot.")
        reply=$(oc_text "$stream")
        expect_not_contains "$reply" "Routes" "the free model read the repo README"
      fi'

  context "when the sandbox config cannot be loaded"

    # Fail-closed. opencode does not error on an unknown --agent; it warns on
    # stderr and silently runs the FULL-PERMISSION default agent instead. If
    # that ever went undetected, every routed prompt would hand a free
    # third-party model tool access to the user'"'"'s repo.
    it "refuses to route rather than falling back to a tool-enabled agent" '
      if ! command -v opencode >/dev/null 2>&1; then
        _fail "opencode CLI not installed"
      else
        printf "%s" "{\"agent\":{\"notfreeloader\":{\"description\":\"x\",\"mode\":\"primary\"}}}" \
          > "$SCRATCH/wrong-agent.json"
        out=$(FREELOADER_AGENT_CONFIG="$SCRATCH/wrong-agent.json" \
              OPENCODE_FREE_CACHE="$SCRATCH/cache.json" OPENCODE_FREE_CACHE_MAX_AGE=99999 \
              "$PROJECT_DIR/scripts/route.sh" "capital of Portugal? one word" 2>/dev/null)
        expect_eq "$out" "" "expected an unsandboxed run to produce no answer"
      fi'

    it "refuses to route when the config file is missing entirely" '
      out=$(FREELOADER_AGENT_CONFIG="$SCRATCH/does-not-exist.json" \
            OPENCODE_FREE_CACHE="$SCRATCH/cache.json" OPENCODE_FREE_CACHE_MAX_AGE=99999 \
            "$PROJECT_DIR/scripts/route.sh" "capital of Portugal? one word" 2>/dev/null)
      expect_eq "$out" "" "expected a missing sandbox config to block routing"'

describe "integration — live usage headers"

  context "against the real Anthropic API"

    it "reports a utilisation figure for both windows" '
      out=$("$PROJECT_DIR/scripts/usage.sh" --json 2>/dev/null)
      if [ -z "$out" ]; then
        _fail "usage.sh produced nothing (no credentials?)"
      else
        h5=$(printf "%s" "$out" | jq -r ".five_hour.utilization")
        d7=$(printf "%s" "$out" | jq -r ".seven_day.utilization")
        expect_not_contains "$h5" "null" "expected a 5h utilisation"
        expect_not_contains "$d7" "null" "expected a 7d utilisation"
      fi'

spec_summary
