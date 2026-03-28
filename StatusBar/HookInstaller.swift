import Foundation

class HookInstaller {
    private let hooksDir: String
    private let settingsPath: String
    private let hookScript: String
    private let hookCommand = "bash ~/.claude/hooks/statusbar/statusbar.sh"
    private let hookEvents = [
        "SessionStart", "Stop", "SessionEnd",
        "Notification", "PermissionRequest",
        "PreToolUse", "PostToolUse"
    ]

    init() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        hooksDir = "\(home)/.claude/hooks/statusbar"
        settingsPath = "\(home)/.claude/settings.json"
        hookScript = Self.embeddedHookScript
    }

    /// Installs hook script and registers hooks in settings.json if not already present.
    func installIfNeeded() {
        installHookScript()
        registerHooksInSettings()
    }

    /// Removes hook script and deregisters hooks from settings.json.
    func uninstall() {
        deregisterHooksFromSettings()
        try? FileManager.default.removeItem(atPath: hooksDir)
    }

    // MARK: - Hook Script

    private func installHookScript() {
        let fm = FileManager.default
        let scriptPath = "\(hooksDir)/statusbar.sh"

        // Create directory
        try? fm.createDirectory(atPath: hooksDir, withIntermediateDirectories: true)

        // Write script (always overwrite to keep up-to-date)
        try? hookScript.write(toFile: scriptPath, atomically: true, encoding: .utf8)

        // Make executable
        try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptPath)
    }

    // MARK: - Settings.json

    private func registerHooksInSettings() {
        guard var settings = readSettings() else { return }

        var hooks = settings["hooks"] as? [String: Any] ?? [:]
        let hookEntry: [String: Any] = ["type": "command", "command": hookCommand]

        for event in hookEvents {
            var matchers = hooks[event] as? [[String: Any]] ?? []

            // Check if already registered
            let alreadyExists = matchers.contains { matcher in
                let matcherHooks = matcher["hooks"] as? [[String: Any]] ?? []
                return matcherHooks.contains { ($0["command"] as? String) == hookCommand }
            }

            if !alreadyExists {
                if matchers.isEmpty {
                    matchers.append(["matcher": "", "hooks": [hookEntry]])
                } else {
                    var first = matchers[0]
                    var firstHooks = first["hooks"] as? [[String: Any]] ?? []
                    firstHooks.append(hookEntry)
                    first["hooks"] = firstHooks
                    matchers[0] = first
                }
                hooks[event] = matchers
            }
        }

        settings["hooks"] = hooks
        writeSettings(settings)
    }

    private func deregisterHooksFromSettings() {
        guard var settings = readSettings() else { return }
        guard var hooks = settings["hooks"] as? [String: Any] else { return }

        for event in hooks.keys {
            guard var matchers = hooks[event] as? [[String: Any]] else { continue }
            for (i, var matcher) in matchers.enumerated() {
                guard var matcherHooks = matcher["hooks"] as? [[String: Any]] else { continue }
                matcherHooks.removeAll { ($0["command"] as? String) == hookCommand }
                matcher["hooks"] = matcherHooks
                matchers[i] = matcher
            }
            // Remove empty matchers
            matchers.removeAll { matcher in
                (matcher["hooks"] as? [[String: Any]])?.isEmpty ?? true
            }
            if matchers.isEmpty {
                hooks.removeValue(forKey: event)
            } else {
                hooks[event] = matchers
            }
        }

        settings["hooks"] = hooks
        writeSettings(settings)
    }

    private func readSettings() -> [String: Any]? {
        guard let data = FileManager.default.contents(atPath: settingsPath),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return json
    }

    private func writeSettings(_ settings: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys]) else { return }
        try? data.write(to: URL(fileURLWithPath: settingsPath), options: .atomic)
    }

    // MARK: - Embedded Hook Script

    private static let embeddedHookScript = """
    #!/bin/bash
    # Claude Code Status Bar hook — writes status per session to /tmp/claude-status-{session_id}.json

    # Read event JSON from stdin
    INPUT=$(cat)

    # Parse all fields in one python call
    eval "$(echo "$INPUT" | python3 -c "
    import sys, json, shlex
    d = json.load(sys.stdin)
    for k in ('hook_event_name', 'session_id', 'tool_name', 'cwd'):
        print(f'{k.upper()}={shlex.quote(str(d.get(k, \\"\\")))}')
    " 2>/dev/null)"

    EVENT="$HOOK_EVENT_NAME"
    SESSION_ID="$SESSION_ID"
    TOOL_NAME="$TOOL_NAME"
    CWD="$CWD"

    case "$EVENT" in
      PreToolUse|PostToolUse)                STATUS="working" ;;
      Notification)                           STATUS="idle" ;;
      PermissionRequest)                     STATUS="waiting" ;;
      SessionStart|Stop)                     STATUS="idle" ;;
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
                *"Visual Studio Code"*|*code-helper*|*Electron*)
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

    # Detect TTY for terminal window matching
    SESSION_TTY=""
    pid=$$
    for _ in 1 2 3 4 5 6 7 8 9 10; do
        pid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
        [ -z "$pid" ] || [ "$pid" = "1" ] && break
        t=$(ps -o tty= -p "$pid" 2>/dev/null | tr -d ' ')
        if [ -n "$t" ] && [ "$t" != "??" ]; then
            SESSION_TTY="/dev/$t"
            break
        fi
    done

    # Write per-session status file (JSON-escaped via Python to handle special chars in paths)
    STATUS_FILE="/tmp/claude-status-${SESSION_ID}.json"
    _STATUS="$STATUS" _EVENT="$EVENT" _TS="$TIMESTAMP" _SID="$SESSION_ID" \\
    _TOOL="$TOOL_NAME" _CWD="$CWD" _APP="$APP" _TTY="$SESSION_TTY" \\
    python3 -c "
    import json, sys, os
    json.dump({
        'status': os.environ['_STATUS'],
        'event': os.environ['_EVENT'],
        'timestamp': int(os.environ['_TS']),
        'session_id': os.environ['_SID'],
        'tool_name': os.environ['_TOOL'],
        'cwd': os.environ['_CWD'],
        'app': os.environ['_APP'],
        'tty': os.environ['_TTY']
    }, sys.stdout)
    " > "$STATUS_FILE"
    """
}
