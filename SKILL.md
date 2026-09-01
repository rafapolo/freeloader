---
name: freeloader
description: Route cheap, low-stakes prompts to opencode's free-tier models instead of answering with Claude directly, to save Claude tokens. Use when the user says "freeloader", "use the free model", "route this to opencode", "save tokens", or "use a free model for this" — or proactively for a request that is clearly cheap (a short factual lookup, a unit/format conversion, a one-line rewrite/translation, boilerplate with no repo context, a trivial snippet) and does not need repo context, tool calls, file edits, or judgment. Not for anything requiring codebase context, multi-step reasoning, file edits, tool use, or where correctness matters a lot — those stay with Claude. Requires the `opencode` CLI and `jq` on PATH.
---

# Freeloader

Offload cheap prompts to whichever of opencode's free models is fastest and
actually working, instead of spending Claude tokens on them. Everything runs
through the `opencode` CLI, which must already be installed and authenticated
(`opencode providers list` should show at least one provider).

**Read this before routing anything.** Calling `route.sh` yourself, mid-turn, is
the *worst* way to use this skill and usually loses money. You have already read
the conversation; routing adds one more request that re-sends all of it, to save
the handful of tokens you would have spent on the answer. Measured, that is
negative for any conversation over a few hundred tokens — see the README.

The modes that actually save are mechanical and need nothing from you:
`hooks/intercept-hook.sh` answers a trivial prompt before your turn exists, and
`hooks/cap-hook.sh` keeps huge command output out of the conversation. Both run
without your involvement, which is the point.

So: **prefer not routing by hand.** Do it when the user explicitly asks, and
otherwise only for a prompt whose answer would be long (the saving scales with
the output you avoid writing) — never for a one-word lookup, where the extra
request costs more than the answer.

The free model runs **sandboxed and tool-less** — no filesystem, no network, no
repo — in an empty scratch directory. That is enforced mechanically by
`agent/freeloader.json`, and if the sandbox fails to load, routing fails closed
rather than falling back to a tool-enabled agent. It is not a matter of judgment
on your part.

Neither is the prompt text: `scripts/scan.sh` checks every prompt for
credentials and personal data before it is sent, and `route.sh` refuses to send
one that trips it. But that guard only catches *structured* things — keys,
emails, card and document numbers. It cannot recognise a name, a health detail,
or a private situation described in prose, so the no-route list below is still
yours to apply.

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
- involves sensitive, private, or proprietary content — the sandbox stops the
  model going and *fetching* anything, but whatever you put in the prompt still
  goes to a third-party API. Never paste secrets, credentials, or private user
  data into a routed prompt — that includes personal info (names, emails,
  addresses, phone numbers, account/financial details) about the user or
  anyone else. If a prompt can't be scrubbed of it while staying useful, keep
  it with Claude instead of routing. The scanner backs this up for the
  recognisable cases; it does not replace the judgment for the rest.
- is one the user is clearly asking Claude specifically to handle

If genuinely unsure, don't route — just answer normally. Never route silently
on a request that explicitly names Claude or asks for your own reasoning.

**Exception — conserve mode:** when conserve mode is on (see below), widen this:
route anything that isn't clearly repo-context, tool use, multi-step judgment,
or sensitive — even prompts you'd otherwise leave to yourself as borderline.
Still never route on a request that explicitly names Claude or the
sensitive-content case above; conserve mode changes the "is it cheap enough"
bar, not the hard no-route list.

## Workflow

1. **First use in a session (or if the cache looks stale/empty):** run the
   benchmark once, up front, so later routing is instant:

   ```
   scripts/benchmark.sh
   ```

   This discovers free models from real pricing data (`opencode models
   --verbose`, filtered to opencode's own hosted tiers with $0 cost — not a
   "free" name-substring match), probes them in batches, and writes a ranked
   cache to `~/.cache/opencode-free-models.json`. Ranking is by *capability
   first, then speed*: each model gets a liveness probe and an
   instruction-following probe, and only models that pass both are routable
   (see Notes). It's safe to call repeatedly — `route.sh` skips it via a 24h
   freshness check — but calling it explicitly up front avoids paying the
   benchmark latency on the user's first real request.

2. **For each cheap prompt**, route it and read the answer back:

   ```
   scripts/route.sh "<the exact prompt text>"
   ```

   - stdout is the model's reply — relay it to the user.
   - stderr on success names which model answered, e.g. `[routed via opencode/big-pickle]`.
   - On `NO_FREE_MODEL_AVAILABLE` or `ALL_FREE_MODELS_FAILED` (stderr, exit 1),
     just answer the prompt yourself instead — don't retry in a loop.
   - On `PROMPT_CONTAINS_SENSITIVE_DATA: <categories>` (stderr, exit 1), the
     prompt was never sent — it matched the credential/personal-data scan.
     **Answer it yourself.** Do not retry it, do not rephrase or redact it to
     get it past the guard, and do not route a summary of it either. Mention to
     the user that it stayed with you and why (name the category, not the
     value). If they insist it was a false positive, they can confirm with
     `scripts/scan.sh "<text>"` — but the answer is still yours to give.
   - On `FREELOADER_SANDBOX_UNAVAILABLE` (stderr, exit 1), the tool-less agent
     config could not be loaded, so routing refused to run rather than handing
     a free model an unsandboxed session. Answer the prompt yourself, **stop
     routing for the rest of the session**, and tell the user their freeloader
     install looks broken — every prompt will hit this until it's fixed. It is a
     setup problem, not a busy free tier, so retrying other models is pointless.
   - Set `FREELOADER_DEBUG=1` to see per-model failure reasons and opencode's
     own stderr when routing behaves oddly.

3. **Tell the user it was routed.** Briefly note the reply came from a free
   model (name it), so they're not misled about who answered. If they'd
   rather you always answer directly, stop routing for the rest of the
   session.

## Conserve mode

Once Claude's own rate-limit utilization is high, it's worth routing more
aggressively. `hooks/tick-hook.sh` runs as a `UserPromptSubmit` hook (wired up
by `scripts/install.sh`) and handles this without any action from you:

- It's silent in the normal case — no output, no context cost.
- Past `FREELOADER_UTIL_THRESHOLD` (default 0.8) it injects a single line
  saying conserve mode is ON and roughly what the utilization is. When you see
  that line, apply the widened routing rule above.

It is a hook and not a step in this workflow on purpose: as an instruction it
depended on you remembering it every single turn, and one skipped turn silently
disabled the rate-limit awareness with nothing to notice.

If the hook isn't installed (run `scripts/install.sh`), you can tick it by hand
with `scripts/tick.sh`, which prints
`{"conserve_mode": bool, "turns_since_check": int, ...}`. It only spends real
tokens on every 5th call — the other four read a cached value.

## The two hooks that do the real work

Neither needs anything from you; both are installed by `scripts/install.sh`.

**`hooks/intercept-hook.sh`** (`UserPromptSubmit`) — **disabled by default; you
will not normally see this fire.** It answers a trivially self-contained prompt
before your turn exists. Shadow-tested over 7,311 real prompts it fired on 0.47%
and was wrong on most of those — "what are the themes?" looks exactly like "what
is the capital of Portugal?" to a regex — so it ships off. If a user asks about
it, that is the answer; don't suggest enabling it without a triage that decides
on meaning rather than shape.

**`hooks/cap-hook.sh`** (`PreToolUse`) — rewrites known-verbose Bash commands
(test runners, builds) to pipe through `scripts/cap.sh`, which replaces a huge
output with its head, its failure lines, a free-model summary, and its tail.
This is the single biggest saving in the project, because a large tool result is
re-read on every subsequent turn, not just the one it arrived on.

When you see `[freeloader] output capped`, the full output is on disk at the
path printed right below it — read that file if the summary is not enough.
Never conclude a build passed from a summary alone; the verbatim failure lines
are there for exactly that reason.

## Reporting what was saved

```
scripts/stats.sh            # human summary
scripts/stats.sh --json     # machine-readable
```

Every route appends a record to `~/.cache/freeloader-usage.jsonl`, with both
sides of the ledger: what it saved, and what routing itself cost. `net` can be
negative — that is not a bug, it is the honest answer for hand-routing inside a
turn. If the user asks whether this saves anything, run this rather than
estimating, and report the net rather than the saved figure.

## Notes

- **The sandbox is not optional.** `opencode run` defaults to the `build` agent,
  a full coding agent with filesystem tools, rooted in the caller's cwd. Left
  alone it lets a free third-party model read `.env`, credentials and source on
  its own initiative. `agent/freeloader.json` disables every tool by name (a
  `{"*": false}` wildcard is not supported and silently breaks replies), and
  `--dir` points the session at an empty scratch dir. Tool names must be
  maintained by hand: a newly added opencode tool arrives *enabled*.
- **The scan is not optional either, and has no override.** `scripts/scan.sh`
  is deliberately biased toward false positives: a false positive costs one
  prompt answered by Claude — what would have happened anyway without this
  skill — while a miss posts a credential or someone's personal data to a free
  endpoint, permanently. It reports matched *categories* only, never the
  matched text, so the value never reaches stderr, the transcript, or the usage
  log. If `scan.sh` is missing entirely, every prompt is refused
  (`scanner-unavailable`) rather than sent unchecked.
- **Never trust `opencode run`'s exit status.** It exits 0 even when the entire
  event stream is `{"type":"error"}`. `route.sh` parses `--format json` and
  requires no error event, a `step_finish`, and non-empty text before relaying
  anything. Similarly, an unknown `--agent` does not fail — opencode warns on
  stderr and runs the default tool-enabled agent instead, so `lib.sh` treats
  that warning as a hard failure.
- The cache auto-refreshes after 24h (`OPENCODE_FREE_CACHE_MAX_AGE`, seconds).
  Force a re-benchmark any time with `scripts/benchmark.sh`.
- Discovery is by real cost metadata, not model naming — some free models
  don't have "free" in their id (e.g. `opencode/big-pickle`), and a
  substring match would silently miss them. Discovery is also scoped to
  opencode's own hosted providers only (`opencode`, `opencode-go`): a
  bring-your-own-key provider (openai, anthropic, ...) reporting cost 0 could
  just be a metadata gap, and routing there would risk billing your own
  account instead of using opencode's free tier.
- Ranking uses two probes because a liveness ping alone ranks a fast model that
  can't follow an instruction above a slower one that can. Strict mode (both
  probes) relaxes to liveness-only if *no* model clears the higher bar, so a bad
  day for every free model degrades the skill instead of disabling it. Override
  with `OPENCODE_FREE_STRICT=false`.
- A model that fails on a real prompt is **demoted in the cache** on the spot.
  Without that, a model that benchmarks fine but fails in practice stays at rank
  1 and burns its full timeout on every prompt for the rest of the 24h window.
- Per-model timeout for real requests is derived from that model's measured
  benchmark latency (6x, floored at 20s, capped by `OPENCODE_FREE_RUN_TIMEOUT`
  at 60s), so a model that pinged in 4s doesn't hold the user for a full
  minute before falling through. Set `OPENCODE_FREE_ADAPTIVE_TIMEOUT=false` to
  pin every model to the flat ceiling instead.
- `timeout` is not part of a stock macOS. `scripts/lib.sh` resolves
  `timeout`/`gtimeout` when present and falls back to a pure-shell watchdog —
  without it, a missing `timeout` exits 127 and every model reads as broken.
- Run `tests/run.sh` after changing any script; the suite is hermetic (stubs
  `opencode`/`curl`/`security`, spends no tokens). `INTEGRATION=1 tests/run.sh`
  additionally verifies the sandbox against the real opencode CLI.
