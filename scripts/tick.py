#!/usr/bin/env python3
"""Per-turn "tick" for freeloader's usage-aware conserve mode.

Call this once per user turn from SKILL.md's workflow. Cheap on 4 out of
every REFRESH_EVERY calls (pure local file I/O) -- every REFRESH_EVERY-th
call shells out to usage.sh, which spends a few real tokens on a live
Messages API call to read the anthropic-ratelimit-unified-* headers.

Usage: tick.py
Output (stdout, one line of JSON):
  {"conserve_mode": bool, "turns_since_check": int, "checked_at": "...",
   "last_check": {...usage.sh --json output, or null...}}

conserve_mode is true once five_hour.utilization or seven_day.utilization
from the last refresh exceeds FREELOADER_UTIL_THRESHOLD (default 0.8).
SKILL.md reads conserve_mode from this output to decide how aggressively to
route prompts through the free model for the rest of the window.
"""
import json
import os
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path

SKILL_DIR = Path(__file__).resolve().parent.parent
STATE_PATH = Path(os.environ.get("FREELOADER_STATE", Path.home() / ".cache" / "freeloader-state.json"))
REFRESH_EVERY = int(os.environ.get("FREELOADER_REFRESH_EVERY", "5"))
UTIL_THRESHOLD = float(os.environ.get("FREELOADER_UTIL_THRESHOLD", "0.8"))


def load_state():
    try:
        return json.loads(STATE_PATH.read_text())
    except (FileNotFoundError, json.JSONDecodeError):
        return {"turns_since_check": 0, "conserve_mode": False, "checked_at": None, "last_check": None}


def save_state(state):
    STATE_PATH.parent.mkdir(parents=True, exist_ok=True)
    tmp = STATE_PATH.with_suffix(".tmp")
    tmp.write_text(json.dumps(state))
    tmp.replace(STATE_PATH)  # atomic on POSIX


def refresh_usage():
    """Run usage.sh --json. Returns parsed dict, or None on any failure
    (missing credentials, network error, non-zero exit) -- callers must not
    block the turn on this, just keep the previous conserve_mode."""
    try:
        out = subprocess.run(
            [str(SKILL_DIR / "scripts" / "usage.sh"), "--json"],
            capture_output=True, text=True, timeout=30,
        )
        if out.returncode != 0 or not out.stdout.strip():
            return None
        return json.loads(out.stdout)
    except (subprocess.TimeoutExpired, json.JSONDecodeError, OSError):
        return None


def main():
    state = load_state()
    state["turns_since_check"] = state.get("turns_since_check", 0) + 1

    if state["turns_since_check"] >= REFRESH_EVERY:
        usage = refresh_usage()
        if usage is not None:
            h5 = (usage.get("five_hour") or {}).get("utilization") or 0
            d7 = (usage.get("seven_day") or {}).get("utilization") or 0
            state["conserve_mode"] = (h5 > UTIL_THRESHOLD) or (d7 > UTIL_THRESHOLD)
            state["turns_since_check"] = 0
            state["checked_at"] = datetime.now(timezone.utc).isoformat()
            state["last_check"] = usage
        else:
            # Refresh failed -- don't reset the counter, so we simply retry
            # on the next turn instead of waiting a full cycle again.
            state["turns_since_check"] -= 1

    save_state(state)
    print(json.dumps({
        "conserve_mode": state["conserve_mode"],
        "turns_since_check": state["turns_since_check"],
        "checked_at": state.get("checked_at"),
        "last_check": state.get("last_check"),
    }))


if __name__ == "__main__":
    main()
