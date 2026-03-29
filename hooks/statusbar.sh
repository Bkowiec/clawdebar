#!/bin/bash
# Claude Code Status Bar hook — writes status per session to /tmp/claude-status-{session_id}.json
# All logic is in Python for safe JSON handling and atomic writes.

exec python3 -c '
import json, sys, os, time, subprocess, tempfile

data = json.load(sys.stdin)

event = data.get("hook_event_name", "")
session_id = data.get("session_id", "")
tool_name = data.get("tool_name", "")
cwd = data.get("cwd", "")

# SessionEnd: remove status file and exit
if event == "SessionEnd":
    try:
        os.unlink(f"/tmp/claude-status-{session_id}.json")
    except FileNotFoundError:
        pass
    sys.exit(0)

# Map events to states
status = {
    "PreToolUse": "working",
    "PostToolUse": "working",
    "PermissionRequest": "waiting",
    "SessionStart": "idle",
    "Stop": "idle",
}.get(event)

if not status:
    sys.exit(0)

timestamp = int(time.time())

def detect_app():
    pid = os.getpid()
    for _ in range(10):
        try:
            out = subprocess.check_output(
                ["ps", "-o", "ppid=,comm=", "-p", str(pid)],
                stderr=subprocess.DEVNULL, text=True
            ).strip()
        except Exception:
            break
        if not out:
            break
        parts = out.split(None, 1)
        if len(parts) < 2:
            break
        ppid, comm = int(parts[0]), parts[1]
        if ppid <= 1:
            break
        for pattern, name in [
            ("Visual Studio Code", "VSCode"), ("code-helper", "VSCode"), ("Electron", "VSCode"),
            ("Terminal", "Terminal"), ("iTerm", "iTerm"), ("Warp", "Warp"),
            ("Alacritty", "Alacritty"), ("kitty", "kitty"), ("WezTerm", "WezTerm"), ("wezterm", "WezTerm"),
        ]:
            if pattern in comm:
                return name
        pid = ppid
    tp = os.environ.get("TERM_PROGRAM", "")
    return {"vscode": "VSCode", "iTerm.app": "iTerm", "WarpTerminal": "Warp", "Apple_Terminal": "Terminal"}.get(tp, "Unknown")

def detect_tty():
    pid = os.getpid()
    for _ in range(10):
        try:
            out = subprocess.check_output(
                ["ps", "-o", "ppid=,tty=", "-p", str(pid)],
                stderr=subprocess.DEVNULL, text=True
            ).strip()
        except Exception:
            break
        if not out:
            break
        parts = out.split()
        if len(parts) < 2:
            break
        try:
            ppid = int(parts[0])
        except ValueError:
            break
        tty = parts[1]
        if ppid <= 1:
            break
        if tty and tty != "??":
            return f"/dev/{tty}"
        pid = ppid
    return ""

payload = json.dumps({
    "status": status,
    "event": event,
    "timestamp": timestamp,
    "session_id": session_id,
    "tool_name": tool_name,
    "cwd": cwd,
    "app": detect_app(),
    "tty": detect_tty(),
})

# Atomic write: temp file + rename
status_file = f"/tmp/claude-status-{session_id}.json"
fd, tmp_path = tempfile.mkstemp(dir="/tmp", prefix=".claude-status-", suffix=".tmp")
try:
    os.write(fd, payload.encode())
    os.close(fd)
    os.rename(tmp_path, status_file)
except Exception:
    try:
        os.close(fd)
    except OSError:
        pass
    try:
        os.unlink(tmp_path)
    except OSError:
        pass
'
