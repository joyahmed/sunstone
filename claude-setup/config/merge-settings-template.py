#!/usr/bin/env python3
"""Idempotently merge a settings.json *template* into a Claude Code settings.json.

Usage: merge-settings-template.py <settings.json> <template.json>

Rules (the Node port, merge-settings-template.mjs, applies exactly the same):
- "hooks": for each event in the template, append every entry whose command is
  not already registered under that event. "Already registered" means an entry
  there runs the same command string, or the same script judged by the script
  file's basename - so `bash ~/.claude/hooks/x.sh` and
  `bash /opt/dotfiles/hooks/x.sh` count as one hook. This is the rule
  merge-ai-memory-hook.py uses; the two must agree or a hook ends up registered
  twice under two spellings. A template group's "matcher" (and any other keys on
  the group) is kept on the group that gets appended.
- "statusLine": copied only if the target has none.
- "env": each variable copied only if the target does not define it.
- "permissions" is never read or written. No other template key is copied.
- Commands are written exactly as the template spells them ('~' included).
- The file (and parent dirs) is created if missing. Writes are atomic.
Prints one line per change, or "no change". Exit 0 on success (including a
no-op); non-zero only when a file cannot be parsed or written.
"""
import json, os, re, sys

# Script paths inside a hook command: bare (`bash ~/.claude/hooks/x.sh`,
# `node C:/u/x.js`) or double/single-quoted (`node "C:/my dots/x.js"`).
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


def registered(arr, command):
    want = scripts(command)
    for group in arr:
        if not isinstance(group, dict):
            continue
        for h in group.get("hooks") or []:
            if not isinstance(h, dict):
                continue
            have = h.get("command")
            if have == command or (want and scripts(have) & want):
                return True
    return False


def load(path, required):
    if not os.path.exists(path):
        if required:
            print(f"  ! template not found: {path}", file=sys.stderr)
            sys.exit(1)
        return {}
    try:
        with open(path, "r", encoding="utf-8") as f:
            data = json.load(f) or {}
    except Exception as e:
        print(f"  ! could not parse {path} ({e}); leaving it untouched", file=sys.stderr)
        sys.exit(1)
    if not isinstance(data, dict):
        print(f"  ! {path} is not a JSON object; leaving it untouched", file=sys.stderr)
        sys.exit(1)
    return data


def main():
    if len(sys.argv) != 3:
        print("usage: merge-settings-template.py <settings.json> <template.json>", file=sys.stderr)
        return 2
    path, tpl_path = sys.argv[1], sys.argv[2]
    data = load(path, required=False)
    tpl = load(tpl_path, required=True)
    changes = []

    # hooks
    tpl_hooks = tpl.get("hooks")
    if isinstance(tpl_hooks, dict):
        hooks = data.get("hooks")
        if not isinstance(hooks, dict):
            hooks = {}
        for event, groups in tpl_hooks.items():
            if not isinstance(groups, list):
                continue
            arr = hooks.get(event)
            if not isinstance(arr, list):
                arr = []
            for group in groups:
                if not isinstance(group, dict):
                    continue
                missing = []
                for h in group.get("hooks") or []:
                    if not isinstance(h, dict) or not h.get("command"):
                        continue
                    if not registered(arr, h["command"]) and not registered(
                        [{"hooks": missing}], h["command"]
                    ):
                        missing.append(h)
                if not missing:
                    continue
                new_group = {k: v for k, v in group.items() if k != "hooks"}
                new_group["hooks"] = missing
                arr.append(new_group)
                for h in missing:
                    changes.append(f"registered {event} hook: {h['command'][:60]}"
                                   + ("..." if len(h["command"]) > 60 else ""))
            if arr:
                hooks[event] = arr
        if hooks:
            data["hooks"] = hooks

    # statusLine
    if "statusLine" in tpl and "statusLine" not in data:
        data["statusLine"] = tpl["statusLine"]
        changes.append("set statusLine")

    # env
    tpl_env = tpl.get("env")
    if isinstance(tpl_env, dict):
        env = data.get("env")
        if not isinstance(env, dict):
            env = {}
        for k, v in tpl_env.items():
            if k not in env:
                env[k] = v
                changes.append(f"set env.{k}")
        if env:
            data["env"] = env

    if not changes:
        print("  no change")
        return 0

    for c in changes:
        print("  " + c)
    os.makedirs(os.path.dirname(path) or ".", exist_ok=True)
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(data, f, indent=2, ensure_ascii=False)
        f.write("\n")
    os.replace(tmp, path)
    return 0


if __name__ == "__main__":
    sys.exit(main())
