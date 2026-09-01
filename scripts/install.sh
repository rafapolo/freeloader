#!/usr/bin/env bash
# Installs freeloader so Claude Code can actually use it.
#
# Usage: install.sh [--dry-run] [--no-hook] [--uninstall]
#
# Two steps, both idempotent:
#   1. symlink this checkout into ~/.claude/skills/freeloader — until this
#      exists, Claude's Skill tool cannot see the skill at all and none of the
#      routing ever runs.
#   2. register hooks/tick-hook.sh as a UserPromptSubmit hook in
#      ~/.claude/settings.json, so conserve mode ticks mechanically instead of
#      depending on the model remembering a step-0 instruction.
#
# settings.json is backed up before it is touched, and the hook entry is merged
# into whatever is already there — existing hooks are preserved.
set -uo pipefail

SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CLAUDE_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
SKILLS_DIR="$CLAUDE_DIR/skills"
LINK="$SKILLS_DIR/freeloader"
SETTINGS="$CLAUDE_DIR/settings.json"
HOOK_CMD="$SKILL_DIR/hooks/tick-hook.sh"

# Every hook this project installs, as "<event> <script>". The two added after
# tick-hook are the ones that make routing pay for itself: answering a trivial
# prompt without starting a Claude turn, and keeping a huge command output from
# entering the conversation at all. See README.
HOOKS="UserPromptSubmit $SKILL_DIR/hooks/tick-hook.sh
UserPromptSubmit $SKILL_DIR/hooks/intercept-hook.sh
PreToolUse $SKILL_DIR/hooks/cap-hook.sh"

DRY_RUN=false
WITH_HOOK=true
UNINSTALL=false

while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run)   DRY_RUN=true; shift ;;
    --no-hook)   WITH_HOOK=false; shift ;;
    --uninstall) UNINSTALL=true; shift ;;
    -h|--help)   grep '^# ' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

command -v jq >/dev/null 2>&1 || { echo "jq is required" >&2; exit 1; }

say() { printf '  %s\n' "$1"; }
run() { if [ "$DRY_RUN" = true ]; then say "would: $*"; else "$@"; fi; }

# ---------------------------------------------------------------------------
# uninstall
# ---------------------------------------------------------------------------

if [ "$UNINSTALL" = true ]; then
  echo "Uninstalling freeloader"
  if [ -L "$LINK" ]; then run rm "$LINK"; say "removed $LINK"; else say "no symlink at $LINK"; fi

  if [ -f "$SETTINGS" ] && jq -e . "$SETTINGS" >/dev/null 2>&1; then
    updated=$(cat "$SETTINGS")
    while IFS=' ' read -r event cmd; do
      [ -n "$event" ] || continue
      updated=$(printf '%s' "$updated" | jq --arg cmd "$cmd" --arg ev "$event" '
        if .hooks[$ev] then
          .hooks[$ev] = (
            [ .hooks[$ev][]
              | .hooks = [ (.hooks // [])[] | select(.command != $cmd) ] ]
            | map(select((.hooks | length) > 0)) )
          | if (.hooks[$ev] | length) == 0 then del(.hooks[$ev]) else . end
          | if (.hooks | length) == 0 then del(.hooks) else . end
        else . end')
    done <<EOF
$HOOKS
EOF
    if [ "$DRY_RUN" = true ]; then
      say "would rewrite $SETTINGS without the freeloader hooks"
    else
      cp "$SETTINGS" "$SETTINGS.freeloader-backup.$(date +%s)"
      printf '%s\n' "$updated" > "$SETTINGS"
      say "removed hooks from $SETTINGS"
    fi
  fi
  echo "Done. Cached state in ~/.cache/freeloader-* and ~/.cache/opencode-free-models.json was left alone."
  exit 0
fi

# ---------------------------------------------------------------------------
# preflight
# ---------------------------------------------------------------------------

echo "Installing freeloader from $SKILL_DIR"
echo

echo "Checking requirements"
missing=0
for c in opencode jq; do
  if command -v "$c" >/dev/null 2>&1; then say "✓ $c"; else say "✗ $c — required"; missing=1; fi
done
if command -v timeout >/dev/null 2>&1 || command -v gtimeout >/dev/null 2>&1; then
  say "✓ timeout"
else
  say "· timeout not found — using the pure-shell watchdog in lib.sh (fine)"
fi
[ "$missing" -eq 0 ] || { echo; echo "Install the missing requirements first." >&2; exit 1; }
echo

# ---------------------------------------------------------------------------
# 1. skill symlink
# ---------------------------------------------------------------------------

echo "1. Registering the skill"
run mkdir -p "$SKILLS_DIR"
if [ -L "$LINK" ]; then
  current="$(readlink "$LINK")"
  if [ "$current" = "$SKILL_DIR" ]; then
    say "already linked: $LINK"
  else
    say "relinking $LINK (was $current)"
    run rm "$LINK" && run ln -s "$SKILL_DIR" "$LINK"
  fi
elif [ -e "$LINK" ]; then
  say "✗ $LINK exists and is not a symlink — leaving it alone"
else
  run ln -s "$SKILL_DIR" "$LINK"
  say "linked $LINK -> $SKILL_DIR"
fi
echo

# ---------------------------------------------------------------------------
# 2. conserve-mode hook
# ---------------------------------------------------------------------------

if [ "$WITH_HOOK" = true ]; then
  echo "2. Registering hooks"

  if [ -f "$SETTINGS" ] && ! jq -e . "$SETTINGS" >/dev/null 2>&1; then
    say "✗ $SETTINGS is not valid JSON — skipping, fix it and re-run"
  else
    [ -f "$SETTINGS" ] || { [ "$DRY_RUN" = true ] || echo '{}' > "$SETTINGS"; }
    existing=$([ -f "$SETTINGS" ] && cat "$SETTINGS" || echo '{}')
    updated="$existing"
    changed=false

    while IFS=' ' read -r event cmd; do
      [ -n "$event" ] || continue
      run chmod +x "$cmd"
      if printf '%s' "$updated" | jq -e --arg cmd "$cmd" --arg ev "$event" '
          [ (.hooks[$ev] // [])[] | (.hooks // [])[] | .command ] | index($cmd)' \
          >/dev/null 2>&1; then
        say "already registered: $event -> $(basename "$cmd")"
      else
        updated=$(printf '%s' "$updated" | jq --arg cmd "$cmd" --arg ev "$event" '
          .hooks //= {}
          | .hooks[$ev] //= []
          | .hooks[$ev] += [{hooks: [{type: "command", command: $cmd}]}]')
        changed=true
        say "$([ "$DRY_RUN" = true ] && echo would\ add || echo added): $event -> $(basename "$cmd")"
      fi
    done <<EOF
$HOOKS
EOF

    if [ "$changed" = true ] && [ "$DRY_RUN" != true ]; then
      backup="$SETTINGS.freeloader-backup.$(date +%s)"
      cp "$SETTINGS" "$backup"
      printf '%s\n' "$updated" > "$SETTINGS"
      say "backup: $backup"
    fi
  fi
else
  echo "2. Skipping hooks (--no-hook)"
  say "without them nothing is intercepted or capped, and routing only happens"
  say "from inside a Claude turn — the mode that measurably costs more than it saves"
fi
echo

echo "Done."
[ "$DRY_RUN" = true ] && echo "(dry run — nothing was changed)"
echo "  Restart Claude Code so it picks up the new skill and hook."
echo "  Then: scripts/benchmark.sh   to warm the model ranking"
echo "        scripts/stats.sh       to see what has been saved"
