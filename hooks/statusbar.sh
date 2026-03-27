#!/bin/bash
# Claude Code Status Bar hook — writes status per session to /tmp/claude-status-{session_id}.json

# Read event JSON from stdin
INPUT=$(cat)

# Parse all fields in one python call
eval "$(echo "$INPUT" | python3 -c "
import sys, json, shlex
d = json.load(sys.stdin)
for k in ('hook_event_name', 'session_id', 'tool_name', 'cwd'):
    print(f'{k.upper()}={shlex.quote(str(d.get(k, \"\")))}')
" 2>/dev/null)"

EVENT="$HOOK_EVENT_NAME"
SESSION_ID="$SESSION_ID"
TOOL_NAME="$TOOL_NAME"
CWD="$CWD"

case "$EVENT" in
  SessionStart|PreToolUse|PostToolUse)  STATUS="working" ;;
  Notification|PermissionRequest)        STATUS="waiting" ;;
  Stop)                                  STATUS="idle" ;;
  SessionEnd)
    # Session terminated — delete the status file immediately
    rm -f "/tmp/claude-status-${SESSION_ID}.json"
    exit 0
    ;;
  *)                                     exit 0 ;;
esac

TIMESTAMP=$(date +%s)

# Detect parent app (Terminal, VSCode, iTerm, Warp, etc.)
detect_app() {
    local pid=$$
    local app=""
    for _ in 1 2 3 4 5 6 7 8 9 10; do
        pid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
        [ -z "$pid" ] || [ "$pid" = "1" ] && break
        local comm
        comm=$(ps -o comm= -p "$pid" 2>/dev/null)
        case "$comm" in
            *"Visual Studio Code"*|*Code*|*code-helper*|*Electron*)
                app="VSCode"; break ;;
            *Terminal*)
                app="Terminal"; break ;;
            *iTerm*|*iTerm2*)
                app="iTerm"; break ;;
            *Warp*)
                app="Warp"; break ;;
            *Alacritty*)
                app="Alacritty"; break ;;
            *kitty*)
                app="kitty"; break ;;
            *WezTerm*|*wezterm*)
                app="WezTerm"; break ;;
        esac
    done
    if [ -z "$app" ]; then
        case "${TERM_PROGRAM:-}" in
            vscode)     app="VSCode" ;;
            iTerm.app)  app="iTerm" ;;
            WarpTerminal) app="Warp" ;;
            Apple_Terminal) app="Terminal" ;;
            *)          app="Unknown" ;;
        esac
    fi
    echo "$app"
}

APP=$(detect_app)

# Write per-session status file
STATUS_FILE="/tmp/claude-status-${SESSION_ID}.json"
cat > "$STATUS_FILE" <<EOF
{"status":"$STATUS","event":"$EVENT","timestamp":$TIMESTAMP,"session_id":"$SESSION_ID","tool_name":"$TOOL_NAME","cwd":"$CWD","app":"$APP"}
EOF

# Clean up stale session files (older than 5 minutes)
find /tmp -name "claude-status-*.json" -mmin +5 -delete 2>/dev/null
