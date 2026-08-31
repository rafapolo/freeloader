---
name: freeloader
description: Route cheap, low-stakes prompts to opencode's free-tier models instead of answering with Claude directly, to save Claude tokens. Use when the user says "freeloader", "use the free model", "route this to opencode", "save tokens", or "use a free model for this" — or proactively for a request that is clearly cheap (a short factual lookup, a unit/format conversion, a one-line rewrite/translation, boilerplate with no repo context, a trivial snippet) and does not need repo context, tool calls, file edits, or judgment. Not for anything requiring codebase context, multi-step reasoning, file edits, tool use, or where correctness matters a lot — those stay with Claude. Requires the `opencode` CLI and `jq` on PATH.
---

# Freeloader

Offload cheap prompts to whichever of opencode's free models is fastest and
actually working, instead of spending Claude tokens on them. Everything runs
through the `opencode` CLI, which must already be installed and authenticated
(`opencode providers list` should show at least one provider).

## Is this prompt "cheap"?

Route to a free model ONLY when the request is self-contained and low-stakes:

- short factual lookups, definitions, trivia
- format/unit conversions, simple date math
- one-off rewrites, tone changes, translations, summarizing a short pasted text
- boilerplate that needs no repo context (a regex, a one-off shell one-liner, a
  small isolated function with no project conventions to match)
- brainstorming / naming a handful of options

Do NOT route when the request:

- needs repo/file context, tool calls, edits, or running project commands
- is multi-step, ambiguous, or requires judgment about *this* conversation
- involves sensitive, private, or proprietary content (it leaves the machine
  to a third-party API — never route secrets, credentials, or private user data)
- is one the user is clearly asking Claude specifically to handle

If genuinely unsure, don't route — just answer normally. Never route silently
on a request that explicitly names Claude or asks for your own reasoning.

**Exception — conserve mode (see Workflow step 0):** once `conserve_mode` is
`true`, widen this: route anything that isn't clearly repo-context, tool use,
multi-step judgment, or sensitive — even prompts you'd otherwise leave to
yourself as borderline. Still never route on a request that explicitly names
Claude or the sensitive-content case above; conserve mode changes the "is it
cheap enough" bar, not the hard no-route list.

## Workflow

0. **Every turn**, tick the usage-aware conserve mode (cheap — pure local
   file I/O on 4 out of every 5 calls):

   ```
   scripts/tick.sh
   ```

   Reads/writes `~/.cache/freeloader-state.json` and prints one line of JSON:
   `{"conserve_mode": bool, "turns_since_check": int, "checked_at": ..., "last_check": {...}}`.
   Every 5th call (`FREELOADER_REFRESH_EVERY`, default 5) it shells out to
   `scripts/usage.sh --json` for real — spending a few real tokens — and sets
   `conserve_mode` from whether `five_hour.utilization` or
   `seven_day.utilization` crossed `FREELOADER_UTIL_THRESHOLD` (default
   `0.8`); the other 4 calls just read the cached value. If the refresh
   itself fails (no credentials, network), it keeps the previous
   `conserve_mode` and retries next turn rather than waiting a full cycle.
   Read `conserve_mode` from the output and apply the widened routing rule
   above when it's `true`. `last_check` carries the actual utilization
   numbers if you want to tell the user why you're routing more aggressively.

1. **First use in a session (or if the cache looks stale/empty):** run the
   benchmark once, up front, so later routing is instant:

   ```
   scripts/benchmark.sh
   ```

   This discovers free models from real pricing data (`opencode models
   --verbose`, filtered to opencode's own hosted tiers with $0 cost — not a
   "free" name-substring match), fires one canary prompt at all of them *in
   parallel*, and writes a ranked cache to
   `~/.cache/opencode-free-models.json` (ranked: working models first, then
   fastest first). It's safe to call repeatedly — cheap to skip via `route.sh`'s
   own 24h freshness check, but calling it explicitly up front avoids paying
   the benchmark latency on the user's first real request.

2. **For each cheap prompt**, route it and read the answer back:

   ```
   scripts/route.sh "<the exact prompt text>"
   ```

   - stdout is the model's reply — relay it to the user.
   - stderr on success names which model answered, e.g. `[routed via opencode/mimo-v2.5-free]`.
   - On `NO_FREE_MODEL_AVAILABLE` or `ALL_FREE_MODELS_FAILED` (stderr, exit 1),
     just answer the prompt yourself instead — don't retry in a loop.

3. **Tell the user it was routed.** Briefly note the reply came from a free
   model (name it), so they're not misled about who answered. If they'd
   rather you always answer directly, stop routing for the rest of the
   session.

## Notes

- The cache auto-refreshes after 24h (`OPENCODE_FREE_CACHE_MAX_AGE`, seconds).
  Force a re-benchmark any time with `scripts/benchmark.sh`.
- Discovery is by real cost metadata, not model naming — some free models
  don't have "free" in their id (e.g. `opencode/big-pickle`), and a
  substring match would silently miss them. Discovery is also scoped to
  opencode's own hosted providers only (`opencode`, `opencode-go`): a
  bring-your-own-key provider (openai, anthropic, ...) reporting cost 0 could
  just be a metadata gap, and routing there would risk billing your own
  account instead of using opencode's free tier.
- Free models vary wildly in latency (single-digit seconds to 20s+) and some
  listed "free" models can error out entirely (unsupported, server errors) —
  that's exactly what the benchmark's `ok`/`latency_ms` ranking filters for.
- Per-model timeout for real requests is derived from that model's measured
  benchmark latency (6x, floored at 20s, capped by `OPENCODE_FREE_RUN_TIMEOUT`
  at 60s), so a model that pinged in 4s doesn't hold the user for a full
  minute before falling through. Set `OPENCODE_FREE_ADAPTIVE_TIMEOUT=false` to
  pin every model to the flat ceiling instead.
- `timeout` is not part of a stock macOS. `scripts/lib.sh` resolves
  `timeout`/`gtimeout` when present and falls back to a pure-shell watchdog —
  without it, a missing `timeout` exits 127 and every model reads as broken.
- Run `tests/run.sh` after changing any script; the suite is hermetic (stubs
  `opencode`/`curl`/`security`, spends no tokens).
