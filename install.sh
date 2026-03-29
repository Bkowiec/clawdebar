#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_NAME="Clawdebar"
APP_BUNDLE="$HOME/Applications/$APP_NAME.app"
HOOKS_DIR="$HOME/.claude/hooks/statusbar"

echo "=== Clawdebar Installer ==="

# 1. Build the Swift app
echo "Building $APP_NAME..."
cd "$SCRIPT_DIR"
swift build -c release 2>&1

BIN_PATH="$(swift build -c release --show-bin-path 2>/dev/null)"
BINARY="$BIN_PATH/$APP_NAME"

# 2. Create .app bundle
echo "Creating app bundle at $APP_BUNDLE..."
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"
cp "$BINARY" "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
cp "$SCRIPT_DIR/StatusBar/Info.plist" "$APP_BUNDLE/Contents/"

# Add bundle identifier to Info.plist
/usr/libexec/PlistBuddy -c "Add :CFBundleIdentifier string com.clawdebar.app" "$APP_BUNDLE/Contents/Info.plist" 2>/dev/null || true
/usr/libexec/PlistBuddy -c "Add :CFBundleName string Clawdebar" "$APP_BUNDLE/Contents/Info.plist" 2>/dev/null || true
/usr/libexec/PlistBuddy -c "Add :CFBundleExecutable string Clawdebar" "$APP_BUNDLE/Contents/Info.plist" 2>/dev/null || true
/usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string AppIcon" "$APP_BUNDLE/Contents/Info.plist" 2>/dev/null || true

# Set version from git tag (fallback to "dev" for local builds)
VERSION=$(git describe --tags --abbrev=0 2>/dev/null || echo "dev")
VERSION=${VERSION#v}
/usr/libexec/PlistBuddy -c "Add :CFBundleShortVersionString string $VERSION" "$APP_BUNDLE/Contents/Info.plist" 2>/dev/null || \
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP_BUNDLE/Contents/Info.plist"

# Generate app icon
echo "Generating app icon..."
swift "$SCRIPT_DIR/scripts/generate-icon.swift" > /dev/null 2>&1
iconutil -c icns "$SCRIPT_DIR/Clawdebar.iconset" -o "$APP_BUNDLE/Contents/Resources/AppIcon.icns"
rm -rf "$SCRIPT_DIR/Clawdebar.iconset"

# 3. Install hook script
echo "Installing hook script..."
mkdir -p "$HOOKS_DIR"
cp "$SCRIPT_DIR/hooks/statusbar.sh" "$HOOKS_DIR/statusbar.sh"
chmod +x "$HOOKS_DIR/statusbar.sh"

# 4. Update Claude Code settings.json
SETTINGS="$HOME/.claude/settings.json"
echo "Updating Claude Code hooks in $SETTINGS..."

python3 << 'PYEOF'
import json, sys, os

settings_path = os.path.expanduser("~/.claude/settings.json")

with open(settings_path, "r") as f:
    settings = json.load(f)

hooks = settings.setdefault("hooks", {})
hook_cmd = "bash ~/.claude/hooks/statusbar/statusbar.sh"
hook_entry = {"type": "command", "command": hook_cmd}

# Events the statusbar hook needs
events = ["SessionStart", "Stop", "SessionEnd", "PermissionRequest", "PreToolUse", "PostToolUse"]

for event in events:
    matchers = hooks.setdefault(event, [])
    # Check if statusbar hook already exists
    already_exists = False
    for matcher in matchers:
        for h in matcher.get("hooks", []):
            if h.get("command") == hook_cmd:
                already_exists = True
                break
    if not already_exists:
        # Add to existing matcher or create new one
        if matchers:
            matchers[0].setdefault("hooks", []).append(hook_entry)
        else:
            matchers.append({"matcher": "", "hooks": [hook_entry]})

with open(settings_path, "w") as f:
    json.dump(settings, f, indent=2)

print("  Hooks configured for:", ", ".join(events))
PYEOF

echo ""
echo "=== Clawdebar installation complete! ==="
echo ""
echo "To start: open $APP_BUNDLE"
echo "The app auto-registers as a Login Item on first launch."
