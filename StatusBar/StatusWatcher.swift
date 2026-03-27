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
}

struct ClaudeStatus {
    let state: ClaudeState
    let event: String
    let timestamp: TimeInterval
    let sessionId: String
    let previousState: ClaudeState
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
    private let staleIdleTimeout: TimeInterval = 300     // 5 min for idle sessions
    private let staleActiveTimeout: TimeInterval = 1800  // 30 min for working/waiting

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

            // Skip stale sessions — working/waiting get a longer grace period
            let timeout = (state == .idle) ? staleIdleTimeout : staleActiveTimeout
            if now - content.timestamp > timeout {
                try? fm.removeItem(atPath: path)
                continue
            }

            let session = SessionInfo(
                id: content.session_id,
                state: state,
                event: content.event,
                timestamp: content.timestamp,
                toolName: content.tool_name ?? "",
                workingDirectory: content.cwd ?? "",
                app: content.app ?? ""
            )
            newSessions.append(session)
        }

        // Sort: waiting first, then working, then idle
        newSessions.sort { $0.state > $1.state }

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
            previousState: previousAggregated,
            toolName: topSession?.toolName ?? "",
            workingDirectory: topSession?.workingDirectory ?? "",
            app: topSession?.app ?? ""
        )

        onChange(status)
    }
}
