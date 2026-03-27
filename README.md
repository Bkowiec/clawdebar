# Clawdebar

A lightweight macOS menu bar app that keeps you in the loop while Claude Code works.

Stop watching your terminal. Walk away, watch YouTube, grab coffee — you'll get a notification when Claude needs you or finishes the task.

## Features

- **Clawde in your menu bar** — the Claude Code mascot changes color based on status
- **Multi-session support** — tracks all running Claude Code sessions, shows count badge
- **Click to see all sessions** — popover lists every session with status, directory, and terminal app
- **One-click focus** — click a session to jump to its terminal (VSCode, iTerm, Warp, Terminal, etc.)
- **macOS notifications** — get pinged when Claude asks a question or completes a task
- **Sleep prevention** — your MacBook stays awake while any session is working
- **Auto-start on login** — registers itself as a Login Item, survives reboots
- **Auto-cleanup** — stale sessions are removed automatically

## How it works

```
Claude Code hooks → writes JSON to /tmp/claude-status-{session}.json → Swift app watches files
```

Each Claude Code session writes its own status file via [hooks](https://docs.anthropic.com/en/docs/claude-code/hooks). The app watches `/tmp` for changes, aggregates state across all sessions, and shows the highest-priority status:

| Priority | Hook Events | Icon |
|---|---|---|
| Waiting (highest) | `Notification`, `PermissionRequest` | Clawde yellow, blinking |
| Working | `SessionStart`, `PreToolUse`, `PostToolUse` | Clawde orange, pulsing |
| Idle | `Stop` | Clawde gray (template) |

When multiple sessions are active, a badge shows the count (e.g. "3").

## Requirements

- macOS 13.0+ (Ventura or later)
- Xcode or Xcode Command Line Tools (with macOS SDK)
- Python 3 (pre-installed on macOS)
- [Claude Code](https://docs.anthropic.com/en/docs/claude-code)

## Install

```bash
git clone https://github.com/user/claude-code-statusbar.git
cd claude-code-statusbar
./install.sh
```

The installer:
1. Builds the Swift app (release mode)
2. Creates `~/Applications/Clawdebar.app`
3. Installs the hook script to `~/.claude/hooks/statusbar/`
4. Adds hooks to your `~/.claude/settings.json` (preserves existing hooks)

Then open the app:

```bash
open ~/Applications/Clawdebar.app
```

The app auto-registers as a Login Item on first launch.

## Supported terminals

The hook script auto-detects which app Claude Code is running in:

| Terminal | Detection | Focus action |
|---|---|---|
| VSCode | Process tree + `TERM_PROGRAM` | `code --goto` + activate |
| Terminal.app | Process tree | AppleScript activate |
| iTerm2 | Process tree | Activate by bundle ID |
| Warp | Process tree | Activate by bundle ID |
| kitty | Process tree | Activate by name |
| Alacritty | Process tree | Activate by name |
| WezTerm | Process tree | Activate by name |

## Uninstall

```bash
./uninstall.sh
```

This removes everything:
1. Kills the running app
2. Deletes `~/Applications/Clawdebar.app` (and its Login Item registration)
3. Removes the hook script from `~/.claude/hooks/statusbar/`
4. Cleans up `~/.claude/settings.json` (removes only statusbar hooks, preserves the rest)
5. Deletes all `/tmp/claude-status-*.json` session files

## Project structure

```
├── Package.swift              # Swift package manifest
├── install.sh                 # One-command installer
├── uninstall.sh               # Clean removal
├── hooks/
│   └── statusbar.sh           # Claude Code hook script
└── StatusBar/
    ├── StatusBarApp.swift      # Menu bar app, popover UI, Clawde icon
    ├── StatusWatcher.swift     # Multi-session file watcher
    ├── SleepManager.swift      # IOKit sleep prevention
    ├── NotificationManager.swift  # macOS notifications
    └── Info.plist              # App config (LSUIElement)
```

## License

MIT
