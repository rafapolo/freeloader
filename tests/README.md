# Tests

```
./run.sh                 # everything (hermetic — no network, no tokens)
./run.sh route           # only specs whose filename matches "route"
INTEGRATION=1 ./run.sh   # also run the live spec (spends real tokens)
```

RSpec-flavoured `describe` / `context` / `it` blocks in plain bash. No
framework, no dependencies beyond `bash`, `jq` and coreutils — the DSL is
~170 lines in `spec_helper.sh`.

The default suite is **hermetic**: it stubs `opencode`, `curl` and `security`
onto `PATH`, so it never touches the network, your Keychain, or your token
budget. `integration_spec.sh` is the exception and is skipped unless
`INTEGRATION=1`, because it calls the real CLI.

| spec | covers |
|---|---|
| `lib_spec.sh` | `run_with_timeout`, including the pure-shell watchdog used when `timeout` is absent |
| `benchmark_spec.sh` | free-model discovery, probing, capability-then-speed ranking |
| `route_spec.sh` | candidate selection, success detection, fallthrough, demotion, the two-sided ledger, the pre-send guard |
| `scan_spec.sh` | what must never be sent, and what must still route |
| `triage_spec.sh` | what can be answered with no conversation context — mostly what cannot |
| `intercept_spec.sh` | answering before the Claude turn exists, and failing open in every other case |
| `cap_spec.sh` | `cap.sh` compressing a large output without losing the failure lines or the exit status |
| `tick_spec.sh` | conserve-mode counter, its cached state, and degradation |
| `usage_spec.sh` | rate-limit reporting, and that no credential ever reaches stdout/stderr |
| `stats_spec.sh` | the savings arithmetic over the usage log |
| `integration_spec.sh` | the real `opencode` CLI: discovery, a live route, and a sandbox that reports no tools and cannot read the cwd |

## Writing one

```bash
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/spec_helper.sh"

describe "thing.sh — area"
  context "when something is true"
    it "does the expected thing" '
      out=$(something)
      expect_contains "$out" "expected"'

spec_summary
```

The body of `it` is a *string*, `eval`ed in the current shell so that
`expect_*` failures reach the counters. Available: `expect_eq`,
`expect_contains`, `expect_not_contains`, `expect_status`, `expect_gt`, and
`_fail` for anything custom. `with_stub_path` + `stub_bin` / `stub_opencode`
fake out external commands; `stub_opencode`'s behaviour is chosen per-example
via `$RUN_BEHAVIOUR` (`ok`, `all_fail`, `error_stream`, `no_finish`,
`empty_reply`, `agent_fallback`, `slow`, `echo` — see `spec_helper.sh`).

Two conventions worth keeping:

- **Test the failure, not just the success.** Most of this project is about
  the ways `opencode` fails *quietly* — exit 0 on an error-only stream, a
  silent fallback to the tool-enabled agent. Those are the examples that earn
  their keep.
- **Say why in a comment** when an example guards a specific past bug or a
  deliberate trade-off. A green checkmark doesn't explain what it is
  protecting.
