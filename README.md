# freeloader

Routes cheap, low-stakes prompts from Claude Code to a free-tier model via the `opencode` CLI, and reads the answer back — so trivial requests cost $0 instead of Claude tokens.

## Concept

Not every prompt needs Claude. A lookup like "capital of Portugal?" or a
unit conversion doesn't need repo context, tool calls, or judgment — it just
needs *an* answer. `opencode` (a separate CLI, https://opencode.ai) gives
access to several models at zero cost. This skill has Claude notice when a
request is that cheap, hand it to the fastest working free model instead of
answering itself, and relay the reply back to you — labeled so you always
know a free model answered, not Claude.

## How it works

1. **Discover** — `scripts/benchmark.sh` asks `opencode models --verbose`
   for real pricing data and keeps only models that are both genuinely $0
   (`cost.input == 0 && cost.output == 0`) *and* from opencode's own hosted
   tiers (`opencode`, `opencode-go`). It deliberately does **not** just grep
   the model name for "free" — some free models don't have "free" in their
   id, and it does **not** trust cost==0 on bring-your-own-key providers
   (openai, anthropic, ...), since a 0 there could be a metadata gap rather
   than a real price, and routing there would risk billing your own account.

2. **Benchmark** — every discovered model gets one canary prompt
   (`"Reply with exactly: pong"`), fired in parallel. Latency and
   pass/fail are recorded and ranked (working models first, fastest first)
   into `~/.cache/opencode-free-models.json`. Some "free" models are slow or
   outright broken — this is what filters those out automatically.

3. **Route** — for each cheap prompt, `scripts/route.sh "<prompt>"` walks
   the ranked list, running `opencode run -m <model> "<prompt>"` until one
   succeeds. It prints the reply on stdout and which model answered on
   stderr. If every free model fails, it exits with an error instead of
   hanging, and Claude answers directly instead.

4. **Cache freshness** — the ranking is reused for 24h, then
   auto-refreshed on the next call. Force a re-benchmark any time by running
   `scripts/benchmark.sh` directly.

See `SKILL.md` for the exact criteria Claude uses to decide a prompt is
"cheap" enough to route, versus prompts that always stay with Claude
(anything needing repo context, edits, tool calls, judgment, or involving
sensitive data).

## Requirements

- [`opencode`](https://opencode.ai) CLI, installed and authenticated
  (`opencode providers list` should show at least one provider)
- `jq`

## Status

This currently lives as a plain project folder, not registered in Claude
Code's skills directory — Claude won't auto-invoke it until it's placed
somewhere Claude's Skill tool looks (e.g. symlinked into `~/.claude/skills/`).
