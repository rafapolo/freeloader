#!/usr/bin/env bash
# Runs every *_spec.sh. All specs are hermetic: they stub `opencode`, `curl`
# and `security`, so nothing hits the network, the real Keychain, or your
# token budget.
#
#   tests/run.sh              # all specs
#   tests/run.sh route        # only specs whose name matches "route"
#   INTEGRATION=1 tests/run.sh   # also run the live integration spec
set -uo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FILTER="${1:-}"

failed=0
total_specs=0

for spec in "$TESTS_DIR"/*_spec.sh; do
  name="$(basename "$spec" _spec.sh)"
  [ -n "$FILTER" ] && case "$name" in *"$FILTER"*) ;; *) continue ;; esac

  # The live spec only runs when explicitly asked for — it spends real tokens.
  if [ "$name" = "integration" ] && [ "${INTEGRATION:-0}" != "1" ]; then
    printf '\n\033[90mskipping integration spec (set INTEGRATION=1 to run; it spends real tokens)\033[0m\n'
    continue
  fi

  total_specs=$((total_specs + 1))
  bash "$spec" || failed=$((failed + 1))
done

printf '\n────────────────────────────────\n'
if [ "$failed" -eq 0 ]; then
  printf '\033[32mall %s spec files passed\033[0m\n' "$total_specs"
else
  printf '\033[31m%s of %s spec files failed\033[0m\n' "$failed" "$total_specs"
fi
exit "$((failed > 0))"
