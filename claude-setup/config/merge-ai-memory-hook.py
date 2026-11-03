#!/usr/bin/env python3
"""Idempotently register the ai-memory-sync SessionStart hook (and, when the
script is installed, the ai-memory-commit SessionEnd hook) in a Claude Code
settings.json, without disturbing any existing config.

Usage: merge-ai-memory-hook.py <path-to-settings.json> <hook-command> [label]

- <label> (default "ai-memory") only names the SessionStart hook in the log
  lines, so setup can call this once per hook it registers and each line says
  which one it was ("registered memory-doctor SessionStart hook").
- Creates the file (and parent dirs) if absent.
- Adds a SessionStart hook entry only if no existing entry under that event
  already runs the same script. "Same" is judged by the script's basename, so
  `bash ~/.claude/hooks/x.sh`, `bash /opt/dotfiles/hooks/x.sh` and
  `bash "/opt/my dots/hooks/x.sh"` count as one hook
  (merge-settings-template.py uses the same rule; the two must agree or a hook
  ends up registered twice under two spellings).
- If <settings dir>/hooks/ai-memory-commit.sh exists, registers it as an async
  SessionEnd hook the same way - but ONLY on the call that registers its
  SessionStart twin, ai-memory-sync. Setup calls this once per SessionStart
  hook it registers, and the commit hook belongs to exactly one of them; doing
  it on every call registered nothing extra (the merge is idempotent) but
  printed the SessionEnd line once per caller. The path is written
  double-quoted, so a home directory with a space in it still works; the caller
  is expected to quote the path inside <hook-command> the same way.
- Preserves every other key and hook (Notification, Stop, ...). Safe to run
  repeatedly.
Exit 0 on success (including no-op), non-zero only on a real write error.
"""
import json, os, re, sys

# Script paths inside a hook command: bare (`bash ~/.claude/hooks/x.sh`,
# `node C:/u/x.js`) or double/single-quoted (`bash "/opt/my dots/x.sh"`).
_EXT = r"\.(?:sh|mjs|js|py)"
_SCRIPT_RE = re.compile(
    r'"([^"]*?' + _EXT + r')"|\'([^\']*?' + _EXT + r')\'|([\w./~\\:-]+' + _EXT + r')\b'
)


def scripts(cmd):
    """Basenames of the script files a hook command runs."""
    out = set()
    for m in _SCRIPT_RE.finditer(cmd or ""):
        path = next(g for g in m.groups() if g is not None)
        out.add(os.path.basename(path.replace("\\", "/")))
    return out


def register(hooks, event, command, extra=None):
    """Add {command} under hooks[event] unless an entry there already runs the
    same command or the same script (by basename). Returns True if added."""
    arr = hooks.setdefault(event, [])
    want = scripts(command)
    for group in arr:
        for h in group.get("hooks", []):
            have = h.get("command")
            if have == command or (want and scripts(have) & want):
                return False
    entry = {"type": "command", "command": command}
    if extra:
        entry.update(extra)
    arr.append({"hooks": [entry]})
    return True


def main():
    if len(sys.argv) not in (3, 4):
        print("usage: merge-ai-memory-hook.py <settings.json> <hook-command> [label]", file=sys.stderr)
        return 2
    path, command = sys.argv[1], sys.argv[2]
    label = sys.argv[3].strip() if len(sys.argv) == 4 and sys.argv[3].strip() else "ai-memory"

    data = {}
    if os.path.exists(path):
        try:
            with open(path, "r", encoding="utf-8") as f:
                data = json.load(f) or {}
        except Exception as e:
            print(f"  ! could not parse {path} ({e}); leaving it untouched", file=sys.stderr)
            return 1

    hooks = data.setdefault("hooks", {})
    changed = False

    if register(hooks, "SessionStart", command):
        changed = True
        print(f"  registered {label} SessionStart hook")
    else:
        print(f"  {label} SessionStart hook already present - no change")

    # SessionEnd: commit whatever the session wrote under the memory tree
    # (MEMORY_DIR, default claude-setup/memory). Deliberately a separate hook
    # from the SessionStart one - this half never touches the network, so
    # ending a session stays instant. The commit is pushed by ai-memory-sync.sh
    # on the next start, where a round trip is already being paid and the user
    # is present if a rebase conflicts.
    #
    # Only the call that registers ai-memory-sync does this: the commit hook is
    # the write half of that one hook, and setup calls this script once per
    # SessionStart hook it registers. Keyed off the command actually being
    # registered rather than the <label>, which is documented as naming the log
    # line and nothing else.
    pairs_with_sync = any(
        os.path.splitext(name)[0] == "ai-memory-sync" for name in scripts(command)
    )
    commit_hook = os.path.join(os.path.dirname(path) or ".", "hooks", "ai-memory-commit.sh")
    if pairs_with_sync and os.path.exists(commit_hook):
        try:
            os.chmod(commit_hook, 0o755)
        except Exception:
            pass
        if register(hooks, "SessionEnd", f'bash "{commit_hook}"', {"async": True}):
            changed = True
            print("  registered ai-memory SessionEnd commit hook")
        else:
            print("  ai-memory SessionEnd hook already present - no change")

    if not changed:
        return 0

    os.makedirs(os.path.dirname(path) or ".", exist_ok=True)
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(data, f, indent=2)
        f.write("\n")
    os.replace(tmp, path)
    return 0


if __name__ == "__main__":
    sys.exit(main())
