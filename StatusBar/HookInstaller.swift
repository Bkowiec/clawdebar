import Foundation

class HookInstaller {
    private let hooksDir: String
    private let settingsPath: String
    private let hookScript: String
    private let hookCommand = "bash ~/.claude/hooks/statusbar/statusbar.sh"
    private let hookEvents = [
        "SessionStart", "Stop", "SessionEnd",
        "PermissionRequest", "PreToolUse", "PostToolUse"
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

    private static let embeddedHookScript = #"""
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
    """#
}
