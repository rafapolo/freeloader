<p align="center"><img src="assets/logo.png" alt="freeloader" width="320"></p>

Routes cheap, low-stakes prompts from Claude Code to a free-tier model via the `opencode` CLI, and reads the answer back — so trivial requests cost $0 instead of Claude tokens.

## How it works

A lookup like "capital of Portugal?" doesn't need repo context, tool calls, or
judgment — it just needs *an* answer. [`opencode`](https://opencode.ai) gives
access to several $0 models. This skill has Claude notice when a request is
that cheap, hand it off, and relay the reply back — labeled, so you always
know a free model answered, not Claude. See `SKILL.md` for the exact
cheap-vs-not criteria (anything needing repo context, edits, tool calls,
multi-step judgment, or sensitive data always stays with Claude).

1. **Discover** (`scripts/benchmark.sh`) — reads `opencode models --verbose`
   and keeps only models that are genuinely $0
   (`cost.input == 0 && cost.output == 0`) on opencode's own hosted tiers
   (`opencode`, `opencode-go`). No name-substring matching (some free models
   don't say "free"), and bring-your-own-key providers are never trusted on
   cost==0 (could bill your own account).
2. **Benchmark** — every discovered model gets one canary prompt in
   parallel; latency and pass/fail are ranked into
   `~/.cache/opencode-free-models.json` (working + fastest first). Filters
   out the "free" models that are slow or broken.
3. **Route** (`scripts/route.sh "<prompt>"`) — walks the ranked list running
   `opencode run -m <model>` until one succeeds, per-model timeout scaled
   from its benchmarked latency. Prints the reply on stdout, the model used
   on stderr. If every model fails, it errors out and Claude answers
   directly instead of hanging.
4. **Cache** — the ranking is reused for 24h, then auto-refreshes.

**Conserve mode** — `scripts/tick.sh` runs once per turn: 4 of every 5 calls
just read a local cache (free); every 5th shells out to `scripts/usage.sh
--json` for your real Claude 5h/7d rate-limit utilization (spends a handful
of real tokens — those numbers only come back from `/v1/messages`) and flips
`conserve_mode = true` past 80% utilization. While it's on, `SKILL.md` widens
what counts as "cheap enough to route." Message-driven, not a background
daemon — only ticks while a session is actively invoking the skill.

Credentials for `usage.sh`, in order: `$ANTHROPIC_AUTH_TOKEN` /
`$ANTHROPIC_API_KEY` → macOS Keychain → Linux Secret Service
(`secret-tool`, unverified) → `~/.claude/.credentials.json` (unverified).
The token is never printed — only status/utilization/reset numbers reach
stdout.

## Tests

```
tests/run.sh                 # full hermetic suite
tests/run.sh route           # only specs matching "route"
INTEGRATION=1 tests/run.sh   # also hit the real opencode CLI + Anthropic API
```

RSpec-flavoured `describe`/`context`/`it` blocks in plain bash, no dependencies.
The default suite is **hermetic** — it stubs `opencode`, `curl` and `security`,
so it touches no network, no Keychain, and no token budget. The live
`integration_spec.sh` is skipped unless `INTEGRATION=1`, because it spends real
tokens. Coverage includes the two regressions that used to silently break the
skill (a missing `timeout` marking every model broken; the brace-counting
parser dropping a working model) and an assertion that no credential ever
reaches stdout or stderr — verified to actually fail when a leak is introduced.

## Requirements

- [`opencode`](https://opencode.ai) CLI, installed and authenticated
  (`opencode providers list` should show at least one provider)
- `jq` — the only hard dependency beyond coreutils; every script is bash + jq
- For `scripts/usage.sh` and `scripts/tick.sh`: a valid Claude API/OAuth
  credential (see How it works above); `secret-tool` only if relying on
  Linux Secret Service auto-discovery instead of an env var
- `timeout`/`gtimeout` is used when present, but is **not** required — a
  pure-shell watchdog covers a stock macOS without coreutils

## Status

This currently lives as a plain project folder, not registered in Claude
Code's skills directory — Claude won't auto-invoke it until it's placed
somewhere Claude's Skill tool looks (e.g. symlinked into `~/.claude/skills/`).
