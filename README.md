<p align="center"><img src="assets/logo.png" alt="freeloader" width="320"></p>

Routes cheap, low-stakes prompts from Claude Code to a free-tier model via the `opencode` CLI, and reads the answer back — so trivial requests cost $0 instead of Claude tokens.

## The uncomfortable finding

The first version of this project measured itself and reported success. Then it
was asked to measure the other side of the ledger:

```
routed 2 of 4 prompts
saved ~26 Claude tokens ≈ $0.0001   ← 13 tokens per route
SKILL.md                 ≈ 2,838 tokens to load
```

**Routing a prompt from inside a Claude turn cannot save money.** Three reasons,
which compound:

1. **A route adds a whole extra request.** Calling `route.sh` ends Claude's turn;
   the reply comes back in a new request that re-sends the entire conversation.
   At cache-read rates ($0.20/MTok) a 30k-token conversation costs $0.006 — to
   save $0.0001.
2. **Relaying an answer costs about the same output tokens as writing it.**
   Output is the expensive side ($10/MTok). Claude emits "Lisbon" either way.
   The only real saving is the reasoning avoided, which for trivia is ~13 tokens
   — exactly what the log measured.
3. **A failed route is pure loss.** Half the prompts fell back after 20-60s of
   timeouts, and Claude answered anyway: full cost, zero saving.

Measured break-even: **a conversation of ~900 tokens.** Real Claude Code sessions
run 30k-350k. The premise was never viable in the mode the project shipped in.

### What fixed it

Not a better router — a different call site. Same free model, same scripts,
measured live across all three modes with a conservative 30k-token context:

| mode | where the call happens | net per route |
|---|---|---|
| `turn` | Claude calls `route.sh` mid-conversation | **-$0.0060** |
| `hook` | answered before the Claude turn exists | **+$0.0060** |
| `cap` | a noisy command's output, compressed on the way in | **+$0.0052** ¹ |

¹ on a 13.7 KB test log (→ 3.9 KB). Real build output runs 10-50× that, and a
large tool result is re-read on *every* later turn, not just the one it arrives
on — so this is the mode with the most headroom, by a wide margin.

The sign flips purely on *where* the route is made. That is why the two hooks
below exist, why they need nothing from the model, and why `stats.sh` now
reports a `net` column that is allowed to be negative.

## How it works

A lookup like "capital of Portugal?" doesn't need repo context, tool calls, or
judgment — it just needs *an* answer. [`opencode`](https://opencode.ai) gives
access to several $0 models. This skill spots requests that cheap, hands them
off, and relays the reply back — labeled, so you always know a free model
answered, not Claude. Per the finding above, the spotting is done by hooks
wherever possible rather than by Claude mid-turn. See `SKILL.md` for the exact
cheap-vs-not criteria (anything needing repo context, edits, tool calls,
multi-step judgment, or sensitive data always stays with Claude).

1. **Discover** (`scripts/benchmark.sh`) — reads `opencode models --verbose`
   and keeps only models that are genuinely $0
   (`cost.input == 0 && cost.output == 0`) on opencode's own hosted tiers
   (`opencode`, `opencode-go`). No name-substring matching (some free models
   don't say "free"), and bring-your-own-key providers are never trusted on
   cost==0 (could bill your own account).
2. **Probe** — every discovered model gets two probes, in batches: does it
   answer at all, and can it follow a short instruction exactly. Ranking is
   capability first, then latency, into `~/.cache/opencode-free-models.json`.
   A liveness ping alone would rank a fast model that can't follow an
   instruction above a slower one that can — and following a short instruction
   is the entire job being routed.
3. **Route** (`scripts/route.sh "<prompt>"`) — walks the ranked list until one
   model succeeds, with a per-model timeout scaled from its benchmarked
   latency. Prints the reply on stdout, the model used on stderr. A model that
   fails here is demoted in the cache immediately, so it doesn't sit at rank 1
   burning its timeout on every later prompt. If every model fails, it errors
   out and Claude answers directly instead of hanging.
4. **Cache** — the ranking is reused for 24h, then auto-refreshes.

**Sandboxing** — `opencode run` defaults to the `build` agent: a full coding
agent, with filesystem tools, rooted in whatever directory you invoked it from.
Pointed at your repo, a free third-party model can read `.env`, credentials and
source *on its own initiative* — which would make the "never route private data"
rule unenforceable. So every routed call runs under `agent/freeloader.json`,
which disables every tool by name, in an empty scratch directory via `--dir`.

This is also the single biggest cost win. Measured on `capital of Portugal? one
word` (21 output tokens):

| | tokens per call |
|---|---|
| default `build` agent | 8,843 |
| sandboxed `freeloader` agent | ~490 |

Nearly all of that overhead is tool schemas the model must never use anyway. On
a rate-limited free tier, the unsandboxed version exhausts your quota ~18x
faster for identical answers.

Two fail-open traps this closes, both of which are silent:

- `opencode run` **exits 0 even when the entire event stream is an error**. A
  "non-empty stdout means success" check relays failures to the user as
  answers. `route.sh` parses `--format json` and requires no error event, a
  `step_finish` (not cut off mid-answer), and actual text.
- An unknown `--agent` **does not fail** — opencode warns on stderr and runs
  the default tool-enabled agent instead. So a dropped config would silently
  undo the sandbox with no visible symptom. That warning is treated as a hard
  failure: worst case a model is skipped, never that it gets its tools back.

When the sandbox itself can't be loaded, routing exits with
`FREELOADER_SANDBOX_UNAVAILABLE` and stops immediately — it does not walk the
rest of the list. That failure is a broken install, not a bad model: every
candidate would fail identically, and demoting them for it would poison a
working ranking and force a needless re-benchmark.

**The pre-send scan** — the sandbox stops the model *fetching* anything, but the
prompt itself still goes to a third-party free tier. That half of "never route
private data" used to be an instruction in `SKILL.md` — i.e. it depended on the
model remembering, every prompt, forever. `scripts/scan.sh` makes it code:
`route.sh` checks every prompt first and exits `PROMPT_CONTAINS_SENSITIVE_DATA`
without sending anything, for API keys and private keys, JWTs and bearer
tokens, `password:`/`API_KEY=` assignments, email addresses, phone numbers,
Luhn-valid card numbers, and CPF/CNPJ/SSN/IBAN.

It is biased toward false positives on purpose. A false positive costs one
prompt answered by Claude — exactly what would have happened without the skill
— while a miss cannot be undone, so there is no override flag. Documentation
placeholders (`API_KEY=your_api_key_here`, `user@example.com`, `$MY_KEY`) are
allowed through, because a guard that fires on every README teaches you to
ignore it. Only the matched *category* is ever reported, never the matched text:
otherwise the refusal would just relocate the leak into stderr and the log. A
missing `scan.sh` refuses everything rather than routing unchecked.

```
scripts/scan.sh "text to check"   # prints categories, exit 1 if unsafe to route
```

It catches structured data, not prose — it cannot recognise a name or a private
situation described in a sentence, so the judgment rule in `SKILL.md` still
carries the rest.

**Where the route is called from decides everything.** The same prompt, the same
free model, the same answer, is worth wildly different amounts depending on
which of three modes it happens in — and `stats.sh` reports them separately for
that reason.

| mode | called from | saves | costs |
|---|---|---|---|
| `turn` | Claude, mid-conversation | the tokens Claude would have spent answering | one extra request re-sending the whole conversation |
| `hook` | `intercept-hook.sh`, before the turn exists | the entire turn — context read plus output | nothing |
| `cap` | `cap-hook.sh`, around a noisy command | the tokens that never entered context, on this turn and every later one | nothing |

**Intercepting** (`hooks/intercept-hook.sh`, `UserPromptSubmit`) — answers a
trivially self-contained prompt from a free model and denies the prompt, so no
Claude turn happens at all. `scripts/triage.sh` decides, through four
independent gates: short and single-line, no word pointing outside the prompt
(pronouns, possessives, paths, task verbs, "claude"), a positive match against a
small allowlist of question shapes, and scan-clean. The asymmetry justifies the
strictness — a false negative costs nothing, while a false positive means a
model that has never seen your repo answers a question about it, with the turn
that would have caught the mistake never running. It fails open everywhere: no
`jq`, no free model, a slow model, an empty reply, an unloaded sandbox — all of
it just lets the prompt through. The answer is labelled, and prefixing any
prompt with `claude,` forces a normal turn.

**Capping** (`hooks/cap-hook.sh`, `PreToolUse` → `scripts/cap.sh`) — the biggest
saving here, and the least glamorous. A 40k-token test log costs input tokens on
the turn it arrives and then gets re-read on *every* following turn; compressing
one is worth thousands of routed lookups. Known-verbose commands (test runners,
builders) are rewritten to pipe through `cap.sh`, which under the threshold is a
byte-exact pass-through and over it emits the head, every line matching a
failure pattern, a free-model summary, and the tail.

It has to be `PreToolUse`: `PostToolUse` fires after the tool has run and
[cannot modify the result](https://code.claude.com/docs/en/hooks) — by then the
log is already in the conversation and the money is spent. Three rules keep the
rewrite honest: only allowlisted verbose commands; nothing containing a pipe,
redirect, subshell or separator (wrapping those changes their meaning); and
`set -o pipefail`, so a failing test suite still reads as failed. The full
output is always written to disk and its path printed — nothing is ever only
summarized. The summary excerpt is head + failure lines + tail rather than the
first N bytes, because a plain head truncation gets a build that fails on its
last line summarized as "no failures were detected", printed directly above the
error that disproves it.

**Conserve mode** — `hooks/tick-hook.sh` runs as a `UserPromptSubmit` hook. It
is silent in the normal case; 4 of every 5 calls just read a local cache (free),
and every 5th shells out to `scripts/usage.sh --json` for your real Claude 5h/7d
rate-limit utilization (a handful of real tokens — those numbers only come back
from `/v1/messages`). Past 80% utilization it injects one line telling Claude to
widen what counts as "cheap enough to route". It's a hook rather than a step in
`SKILL.md` because as an instruction it depended on the model remembering it
every turn, and one skipped turn disabled it silently.

Credentials for `usage.sh`, in order: `$ANTHROPIC_AUTH_TOKEN` /
`$ANTHROPIC_API_KEY` → macOS Keychain → Linux Secret Service
(`secret-tool`, unverified) → `~/.claude/.credentials.json` (unverified).
The token is never printed — only status/utilization/reset numbers reach
stdout.

## Install

```
scripts/install.sh              # symlink the skill + register three hooks
scripts/install.sh --dry-run    # show what it would do first
scripts/install.sh --no-hook    # skill only, no hooks
scripts/install.sh --uninstall
```

Until the skill is symlinked into `~/.claude/skills/`, Claude's Skill tool
cannot see it and none of this ever runs. Three hooks are registered:
`tick-hook.sh` and `intercept-hook.sh` on `UserPromptSubmit`, `cap-hook.sh` on
`PreToolUse`. The installer is idempotent, backs up `~/.claude/settings.json`
before merging, preserves hooks already there, and removes only its own on
`--uninstall`. Restart Claude Code afterwards.

`--no-hook` leaves only hand-routing from inside a Claude turn — the one mode
measured to cost more than it saves. Turn either hook off individually with
`FREELOADER_INTERCEPT=0` or `FREELOADER_CAP=0`.

## What it saved

```
scripts/stats.sh            # human summary
scripts/stats.sh --json
```

Every route appends a record to `~/.cache/freeloader-usage.jsonl` with **both
sides of the ledger** — what it saved, and what routing itself cost:

```
freeloader — routed 12 of 13 prompts to a free model
  saved      ~3,410 Claude tokens  ≈ $0.0281 at claude-sonnet-5 rates
  cost       $0.0180 — 3 extra request(s) re-sending the conversation
  net        $0.0101
  free tier  8,200 tokens spent instead ($0)
  median     2100ms per routed prompt

  by mode
    cap                    4 route(s)   net $0.0812
    hook                   6 route(s)   net $0.0164
    turn                   3 route(s)   net -$0.0180
```

`net` is allowed to be negative, and for `turn` mode it usually is. Reporting
only the saved column is how a tool talks you into believing a premise it is
failing — the cost column is the whole reason the modes above exist. A route
that fails is booked as pure cost: the conversation was re-sent to reach a model
that then did not answer, and Claude answers anyway.

Both figures still understate. The saving ignores that a capped tool result
would have been re-read on every later turn; the cost uses the session
transcript size as a proxy for the context (an over-estimate, recorded by the
hook — deliberately the direction that flatters the project least). Price
against a different model with `FREELOADER_PRICE_MODEL` / `FREELOADER_PRICE_IN`
/ `FREELOADER_PRICE_OUT` / `FREELOADER_PRICE_CACHE_READ` (defaults to Claude
Sonnet 5: $2 / $10 per MTok, cache reads at 0.1×).

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
tokens.

Coverage includes the regressions that used to silently break the skill (a
missing `timeout` marking every model broken; the brace-counting parser dropping
a working model; an error-only stream being relayed as an answer), an assertion
that no credential ever reaches stdout or stderr — verified to actually fail
when a leak is introduced — both directions of the pre-send scan (what must
never be sent, and the ordinary cheap prompts that must still route), the
intercept refusing to fire on anything that touches the conversation and failing
open everywhere else, the cap preserving the failure lines and the exit status,
and, under `INTEGRATION=1`, proof against the real CLI that the routed model
reports **no tools** and cannot read a file out of the working directory. See
[`tests/README.md`](tests/README.md).

## Requirements

- [`opencode`](https://opencode.ai) CLI, installed and authenticated
  (`opencode providers list` should show at least one provider)
- `jq` — the only hard dependency beyond coreutils; every script is bash + jq
- For `scripts/usage.sh` and `scripts/tick.sh`: a valid Claude API/OAuth
  credential (see How it works above); `secret-tool` only if relying on
  Linux Secret Service auto-discovery instead of an env var
- `timeout`/`gtimeout` is used when present, but is **not** required — a
  pure-shell watchdog covers a stock macOS without coreutils
