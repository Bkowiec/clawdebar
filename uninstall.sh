#!/bin/bash
set -e

APP_NAME="Clawdebar"
APP_BUNDLE="$HOME/Applications/$APP_NAME.app"
HOOKS_DIR="$HOME/.claude/hooks/statusbar"
SETTINGS="$HOME/.claude/settings.json"
STATUS_PATTERN="/tmp/claude-status-*.json"

echo "=== Clawdebar Uninstaller ==="

# 1. Kill the app if running
if pgrep -x "$APP_NAME" > /dev/null 2>&1; then
    echo "Stopping $APP_NAME..."
    killall "$APP_NAME" 2>/dev/null || true
fi

# 2. Remove the app bundle
if [ -d "$APP_BUNDLE" ]; then
    echo "Removing $APP_BUNDLE..."
    rm -rf "$APP_BUNDLE"
else
    echo "App bundle not found at $APP_BUNDLE (skipping)"
fi

# 3. Remove hook script
if [ -d "$HOOKS_DIR" ]; then
    echo "Removing hook script from $HOOKS_DIR..."
    rm -rf "$HOOKS_DIR"
else
    echo "Hook directory not found (skipping)"
fi

# 4. Remove hooks from settings.json
if [ -f "$SETTINGS" ]; then
    echo "Removing statusbar hooks from $SETTINGS..."
    python3 << 'PYEOF'
import json, os

settings_path = os.path.expanduser("~/.claude/settings.json")

with open(settings_path, "r") as f:
    settings = json.load(f)

hooks = settings.get("hooks", {})
hook_cmd = "bash ~/.claude/hooks/statusbar/statusbar.sh"

for event in list(hooks.keys()):
    matchers = hooks[event]
    for matcher in matchers:
        matcher["hooks"] = [h for h in matcher.get("hooks", []) if h.get("command") != hook_cmd]
    # Remove empty matchers
    hooks[event] = [m for m in matchers if m.get("hooks")]
    # Remove empty events
    if not hooks[event]:
        del hooks[event]

with open(settings_path, "w") as f:
    json.dump(settings, f, indent=2)

print("  Hooks removed from settings.json")
PYEOF
fi

# 5. Clean up status files
rm -f $STATUS_PATTERN

echo ""
echo "=== Uninstall complete ==="
echo "Clawdebar has been fully removed."
