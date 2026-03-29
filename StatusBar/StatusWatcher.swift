import Foundation

enum ClaudeState: String, Codable, Comparable {
    case idle
    case working
    case waiting  // highest priority

    // waiting > working > idle
    private var priority: Int {
        switch self {
        case .idle: return 0
        case .working: return 1
        case .waiting: return 2
        }
    }

    static func < (lhs: ClaudeState, rhs: ClaudeState) -> Bool {
        lhs.priority < rhs.priority
    }
}

struct SessionInfo: Identifiable {
    let id: String  // session_id
    let state: ClaudeState
    let event: String
    let timestamp: TimeInterval
    let toolName: String
    let workingDirectory: String
    let app: String
    let tty: String
}

struct ClaudeStatus {
    let state: ClaudeState
    let event: String
    let timestamp: TimeInterval
    let sessionId: String
    let toolName: String
    let workingDirectory: String
    let app: String
}

private struct StatusFileContent: Codable {
    let status: String
    let event: String
    let timestamp: TimeInterval
    let session_id: String
    let tool_name: String?
    let cwd: String?
    let app: String?
    let tty: String?
}

/// Resolve symlinks for path comparison (e.g. /tmp → /private/tmp)
private func normalizePath(_ path: String) -> String {
    guard !path.isEmpty else { return path }
    return (path as NSString).resolvingSymlinksInPath
}

class StatusWatcher {
    private let statusDir = "/tmp"
    private let filePrefix = "claude-status-"
    private let onChange: (ClaudeStatus) -> Void
    private var dirSource: DispatchSourceFileSystemObject?
    private var dirFD: Int32 = -1
    private var pollTimer: Timer?
    private(set) var aggregatedState: ClaudeState = .idle
    private(set) var sessions: [SessionInfo] = []
    private let orphanedTimeout: TimeInterval = 5400
    let statsStore = StatsStore()

    init(onChange: @escaping (ClaudeStatus) -> Void) {
        self.onChange = onChange
        startWatching()
        scanAllSessions()
    }

    deinit {
        stopWatching()
    }

    private func startWatching() {
        // Watch /tmp directory for changes
        dirFD = open(statusDir, O_EVTONLY)
        guard dirFD >= 0 else { return }

        dirSource = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: dirFD,
            eventMask: [.write],
            queue: .main
        )

        dirSource?.setEventHandler { [weak self] in
            self?.scanAllSessions()
        }

        dirSource?.setCancelHandler { [weak self] in
            if let fd = self?.dirFD, fd >= 0 { close(fd) }
        }

        dirSource?.resume()

        // Also poll every 2s as a safety net (dir events can be noisy/missed)
        pollTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            self?.scanAllSessions()
        }
    }

    private func stopWatching() {
        dirSource?.cancel()
        dirSource = nil
        pollTimer?.invalidate()
    }

    /// Discover running `claude` processes that have no status file and create one for them.
    /// Safe to call from any thread — file creation happens here, then scanAllSessions
    /// is dispatched to main queue for thread-safe state updates.
    func discoverRunningSessions() {
        // Find all PIDs of processes named "claude"
        let pgrep = Process()
        pgrep.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        pgrep.arguments = ["-x", "claude"]
        let pgrepPipe = Pipe()
        pgrep.standardOutput = pgrepPipe
        pgrep.standardError = FileHandle.nullDevice
        try? pgrep.run()
        pgrep.waitUntilExit()

        let pgrepData = pgrepPipe.fileHandleForReading.readDataToEndOfFile()
        guard let pgrepOutput = String(data: pgrepData, encoding: .utf8), !pgrepOutput.isEmpty else { return }

        let allPids = pgrepOutput.split(separator: "\n").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }

        // Filter out child claude processes — keep only the topmost claude per process tree
        let pidSet = Set(allPids)
        var toplevelPids: [Int] = []
        for pid in allPids {
            let ppid = getParentPid(of: pid)
            if pidSet.contains(ppid) { continue }
            toplevelPids.append(pid)
        }

        // Snapshot existing sessions on main queue for thread-safe deduplication
        var existingSessionIds = Set<String>()
        var existingCwds = Set<String>()
        var existingTtys = Set<String>()
        DispatchQueue.main.sync {
            existingSessionIds = Set(sessions.map(\.id))
            existingCwds = Set(sessions.filter { !$0.workingDirectory.isEmpty }.map { normalizePath($0.workingDirectory) })
            existingTtys = Set(sessions.filter { !$0.tty.isEmpty }.map(\.tty))
        }

        let fm = FileManager.default
        let now = Date().timeIntervalSince1970

        // Track TTYs created in this scan to avoid duplicates among discovered PIDs
        var createdTtys = Set<String>()

        for pid in toplevelPids {
            let sessionId = "pid-\(pid)"
            if existingSessionIds.contains(sessionId) { continue }

            // Get TTY first — most reliable dedup key
            let tty = getTty(of: pid)

            // Skip if an existing hook-created session already owns this TTY
            if !tty.isEmpty && existingTtys.contains(tty) { continue }

            // Skip if another discovered PID in this scan already claimed this TTY
            if !tty.isEmpty && createdTtys.contains(tty) { continue }

            // Get working directory via lsof
            let cwd = getCwd(of: pid)

            // Skip if we already have a session for this directory
            if !cwd.isEmpty && existingCwds.contains(normalizePath(cwd)) { continue }

            // Detect parent terminal app by walking up the process tree
            let app = detectParentApp(pid: pid)

            let statusFile = "/tmp/\(filePrefix)\(sessionId).json"
            let payload: [String: Any] = [
                "status": "idle", "event": "Discovered", "timestamp": Int(now),
                "session_id": sessionId, "tool_name": "", "cwd": cwd, "app": app, "tty": tty
            ]
            if let jsonData = try? JSONSerialization.data(withJSONObject: payload) {
                // Atomic write via temp file + rename
                let tmpPath = "/tmp/.claude-status-\(sessionId).tmp"
                if fm.createFile(atPath: tmpPath, contents: jsonData) {
                    try? fm.moveItem(atPath: tmpPath, toPath: statusFile)
                }
            }

            if !tty.isEmpty { createdTtys.insert(tty) }
        }

        // Re-scan to pick up newly created files (must run on main queue for thread safety)
        DispatchQueue.main.sync {
            scanAllSessions()
        }
    }

    /// Check if a process is alive and not a zombie.
    private func isProcessAlive(_ pid: Int32) -> Bool {
        guard kill(pid, 0) == 0 else { return false }
        // Check process state via ps to detect zombies
        let ps = Process()
        ps.executableURL = URL(fileURLWithPath: "/bin/ps")
        ps.arguments = ["-o", "state=", "-p", "\(pid)"]
        let pipe = Pipe()
        ps.standardOutput = pipe
        ps.standardError = FileHandle.nullDevice
        try? ps.run()
        ps.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let state = (String(data: data, encoding: .utf8) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return !state.hasPrefix("Z")
    }

    private func getParentPid(of pid: Int) -> Int {
        let ps = Process()
        ps.executableURL = URL(fileURLWithPath: "/bin/ps")
        ps.arguments = ["-o", "ppid=", "-p", "\(pid)"]
        let pipe = Pipe()
        ps.standardOutput = pipe
        ps.standardError = FileHandle.nullDevice
        try? ps.run()
        ps.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = (String(data: data, encoding: .utf8) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return Int(output) ?? 1
    }

    private func getTty(of pid: Int) -> String {
        let ps = Process()
        ps.executableURL = URL(fileURLWithPath: "/bin/ps")
        ps.arguments = ["-o", "tty=", "-p", "\(pid)"]
        let pipe = Pipe()
        ps.standardOutput = pipe
        ps.standardError = FileHandle.nullDevice
        try? ps.run()
        ps.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let raw = (String(data: data, encoding: .utf8) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return (raw != "??" && !raw.isEmpty) ? "/dev/\(raw)" : ""
    }

    private func getCwd(of pid: Int) -> String {
        let lsof = Process()
        lsof.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        lsof.arguments = ["-a", "-d", "cwd", "-Fn", "-p", "\(pid)"]
        let pipe = Pipe()
        lsof.standardOutput = pipe
        lsof.standardError = FileHandle.nullDevice
        try? lsof.run()
        lsof.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8) ?? ""
        for line in output.split(separator: "\n") {
            if line.hasPrefix("n/") {
                return String(line.dropFirst(1))
            }
        }
        return ""
    }

    /// Walk up the process tree to detect the parent terminal application.
    private func detectParentApp(pid: Int) -> String {
        var currentPid = pid
        for _ in 0..<10 {
            let ps = Process()
            ps.executableURL = URL(fileURLWithPath: "/bin/ps")
            ps.arguments = ["-o", "ppid=,comm=", "-p", "\(currentPid)"]
            let pipe = Pipe()
            ps.standardOutput = pipe
            ps.standardError = FileHandle.nullDevice
            try? ps.run()
            ps.waitUntilExit()

            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = (String(data: data, encoding: .utf8) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !output.isEmpty else { break }

            // Parse "  PPID COMM" format
            let parts = output.split(separator: " ", maxSplits: 1)
            guard parts.count == 2, let ppid = Int(parts[0].trimmingCharacters(in: .whitespaces)) else { break }
            if ppid <= 1 { break }

            let comm = String(parts[1])
            if comm.contains("Visual Studio Code") || comm.contains("code-helper") || comm.contains("Electron") { return "VSCode" }
            if comm.contains("Terminal") { return "Terminal" }
            if comm.contains("iTerm") { return "iTerm" }
            if comm.contains("Warp") { return "Warp" }
            if comm.contains("Alacritty") { return "Alacritty" }
            if comm.contains("kitty") { return "kitty" }
            if comm.contains("WezTerm") || comm.contains("wezterm") { return "WezTerm" }

            currentPid = ppid
        }
        return "Unknown"
    }

    private func scanAllSessions() {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(atPath: statusDir) else { return }

        let now = Date().timeIntervalSince1970
        var newSessions: [SessionInfo] = []

        for file in files {
            guard file.hasPrefix(filePrefix), file.hasSuffix(".json") else { continue }
            let path = "\(statusDir)/\(file)"

            guard let data = fm.contents(atPath: path),
                  let content = try? JSONDecoder().decode(StatusFileContent.self, from: data),
                  let state = ClaudeState(rawValue: content.status) else {
                continue
            }

            // Skip stale sessions
            if now - content.timestamp > orphanedTimeout {
                try? fm.removeItem(atPath: path)
                continue
            }

            // For process-discovered sessions, verify the process is still alive and not a zombie
            if content.session_id.hasPrefix("pid-"),
               let pid = Int(content.session_id.dropFirst(4)) {
                if !isProcessAlive(Int32(pid)) {
                    try? fm.removeItem(atPath: path)
                    continue
                }
            }

            let session = SessionInfo(
                id: content.session_id,
                state: state,
                event: content.event,
                timestamp: content.timestamp,
                toolName: content.tool_name ?? "",
                workingDirectory: content.cwd ?? "",
                app: content.app ?? "",
                tty: content.tty ?? ""
            )
            newSessions.append(session)
        }

        // Deduplicate: if a hook session and a pid-* session share the same TTY or CWD,
        // keep the hook session (it has richer data) and remove the synthetic one.
        var ttyOwners: [String: Int] = [:]  // tty -> index of first non-pid session
        var cwdOwners: [String: Int] = [:]
        var indicesToRemove = Set<Int>()

        for (i, s) in newSessions.enumerated() {
            let isSynthetic = s.id.hasPrefix("pid-")

            if !s.tty.isEmpty {
                if let existing = ttyOwners[s.tty] {
                    // Duplicate TTY — remove the synthetic one
                    let existingIsSynthetic = newSessions[existing].id.hasPrefix("pid-")
                    if isSynthetic && !existingIsSynthetic {
                        indicesToRemove.insert(i)
                    } else if !isSynthetic && existingIsSynthetic {
                        indicesToRemove.insert(existing)
                        ttyOwners[s.tty] = i
                    } else {
                        // Both same type — keep the newer one
                        if s.timestamp > newSessions[existing].timestamp {
                            indicesToRemove.insert(existing)
                            ttyOwners[s.tty] = i
                        } else {
                            indicesToRemove.insert(i)
                        }
                    }
                } else {
                    ttyOwners[s.tty] = i
                }
            }

            let normalizedCwd = normalizePath(s.workingDirectory)
            if !normalizedCwd.isEmpty {
                if let existing = cwdOwners[normalizedCwd] {
                    let existingIsSynthetic = newSessions[existing].id.hasPrefix("pid-")
                    if isSynthetic && !existingIsSynthetic {
                        indicesToRemove.insert(i)
                    } else if !isSynthetic && existingIsSynthetic {
                        indicesToRemove.insert(existing)
                        cwdOwners[normalizedCwd] = i
                    }
                } else {
                    cwdOwners[normalizedCwd] = i
                }
            }
        }

        // Remove duplicates and clean up their status files
        for i in indicesToRemove.sorted(by: >) {
            let removed = newSessions.remove(at: i)
            if removed.id.hasPrefix("pid-") {
                try? fm.removeItem(atPath: "\(statusDir)/\(filePrefix)\(removed.id).json")
            }
        }

        // Sort: waiting first, then working, then idle
        newSessions.sort { $0.state > $1.state }

        // Record stats before change detection (time must accumulate even without state changes)
        statsStore.recordScan(sessions: newSessions)

        // Determine aggregated state (highest priority)
        let previousAggregated = aggregatedState
        let newAggregated = newSessions.map(\.state).max() ?? .idle

        // Only notify if something actually changed
        let sessionsChanged = newSessions.map(\.id) != sessions.map(\.id)
            || newSessions.map(\.state) != sessions.map(\.state)
            || newAggregated != previousAggregated

        sessions = newSessions
        aggregatedState = newAggregated

        guard sessionsChanged else { return }

        let topSession = newSessions.first
        let status = ClaudeStatus(
            state: newAggregated,
            event: topSession?.event ?? "",
            timestamp: topSession?.timestamp ?? now,
            sessionId: topSession?.id ?? "",
            toolName: topSession?.toolName ?? "",
            workingDirectory: topSession?.workingDirectory ?? "",
            app: topSession?.app ?? ""
        )

        onChange(status)
    }
}
