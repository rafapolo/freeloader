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

## Usage monitoring

`scripts/usage.sh` reports your live Claude subscription rate-limit usage
(5h and 7d windows) by making one minimal Messages API call and reading the
`anthropic-ratelimit-unified-*` response headers — the same numbers Claude
Code itself is bound by. It costs a handful of real tokens each run (these
headers are only returned by `/v1/messages`, not by lighter endpoints).

```
scripts/usage.sh          # human-readable
scripts/usage.sh --json   # machine-readable
```

Credentials, in order: `$ANTHROPIC_AUTH_TOKEN` / `$ANTHROPIC_API_KEY` if set
(portable, works anywhere) → macOS Keychain ("Claude Code-credentials",
**tested**) → Linux Secret Service via `secret-tool` (`apt install
libsecret-tools` on Debian, `pacman -S libsecret` on Arch — **unverified**,
assumes the same service label Claude Code uses on macOS) → a plain
`~/.claude/.credentials.json` / `~/.config/claude-code/.credentials.json`
file as a last resort on headless Linux (**unverified**). If auto-discovery
comes up empty on Linux, set `ANTHROPIC_AUTH_TOKEN` explicitly — it's the one
path guaranteed to work everywhere. **The token is never printed** — it's
read into a variable, used inline in one `curl` header, and any temp file
holding it is deleted immediately after. Only the resulting rate-limit
numbers (status / utilization / reset time) are ever written to stdout.

## Conserve mode (usage-aware auto-offload)

`scripts/tick.py` is called once per user turn from `SKILL.md`'s workflow.
It's a message-count trigger, not a wall-clock one (`/loop`/`ScheduleWakeup`
only wake on a timer, which doesn't map cleanly to "every N messages" — a
plain per-turn counter does, with no scheduler needed):

- 4 out of every 5 calls (`FREELOADER_REFRESH_EVERY`, default 5): pure local
  file I/O against `~/.cache/freeloader-state.json` — free.
- Every 5th call: shells out to `scripts/usage.sh --json` for real (spends a
  few tokens), and sets `conserve_mode = true` once `five_hour.utilization`
  or `seven_day.utilization` crosses `FREELOADER_UTIL_THRESHOLD` (default
  `0.8`). A failed refresh (no credentials, network) keeps the previous
  `conserve_mode` and retries next turn instead of waiting a full cycle.

When `conserve_mode` is `true`, `SKILL.md` widens what counts as "cheap
enough to route" for the rest of the window — see the Workflow / "Is this
prompt cheap?" sections — until utilization drops back down after the 5h/7d
window resets.

Caveat: this only runs while an interactive session is open and actually
invoking the skill each turn — it's not a background daemon. A cron-based
poller (via the `schedule` skill) independent of any open session was
considered and rejected in favor of this simpler, message-driven approach;
revisit it if you want conserve mode to persist across sessions.

## Requirements

- [`opencode`](https://opencode.ai) CLI, installed and authenticated
  (`opencode providers list` should show at least one provider)
- `jq`
- For `scripts/usage.sh` and `scripts/tick.py`: `python3`, and a valid Claude
  API/OAuth credential (see Usage monitoring above); `secret-tool` only if
  relying on Linux Secret Service auto-discovery instead of an env var

## Status

This currently lives as a plain project folder, not registered in Claude
Code's skills directory — Claude won't auto-invoke it until it's placed
somewhere Claude's Skill tool looks (e.g. symlinked into `~/.claude/skills/`).
