import Foundation

struct SessionStats {
    let sessionId: String
    let startedAt: Date
    var lastState: ClaudeState
    var lastStateChange: Date
    var workingTime: TimeInterval = 0
    var idleTime: TimeInterval = 0
    var totalToolCalls: Int = 0
    var toolUsage: [String: Int] = [:]
    var lastSeenTimestamp: TimeInterval = 0
}

struct DailyStats: Codable {
    let date: String
    var sessionsStarted: Int = 0
    var totalWorkingTime: TimeInterval = 0
    var totalIdleTime: TimeInterval = 0
    var totalToolCalls: Int = 0
    var toolUsage: [String: Int] = [:]
}

struct StatsData: Codable {
    var dailyStats: [String: DailyStats] = [:]
}

class StatsStore {
    private let statsDir: URL
    private let statsFile: URL
    private let queue = DispatchQueue(label: "com.clawdebar.stats")
    private let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.calendar = Calendar(identifier: .gregorian)
        return f
    }()
    private var data: StatsData
    private var liveSessions: [String: SessionStats] = [:]
    private var saveTimer: Timer?
    private var dirty = false

    init() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        statsDir = home.appendingPathComponent(".clawdebar")
        statsFile = statsDir.appendingPathComponent("stats.json")
        data = StatsData()
        load()
        startAutoSave()
    }

    deinit {
        saveTimer?.invalidate()
    }

    // MARK: - Recording

    func recordScan(sessions: [SessionInfo]) {
        queue.sync {
            let now = Date()
            let currentIds = Set(sessions.map(\.id))

            // Finalize sessions that disappeared
            let previousIds = Set(liveSessions.keys)
            for removedId in previousIds.subtracting(currentIds) {
                _finalizeSession(removedId, at: now)
            }

            // Update or create live sessions
            for session in sessions {
                if var live = liveSessions[session.id] {
                    let elapsed = now.timeIntervalSince(live.lastStateChange)
                    accumulateTime(&live, elapsed: elapsed)

                    live.lastState = session.state
                    live.lastStateChange = now

                    // Count tool usage (dedup by timestamp to avoid double-counting from polling)
                    if session.state == .working,
                       !session.toolName.isEmpty,
                       session.timestamp != live.lastSeenTimestamp {
                        live.toolUsage[session.toolName, default: 0] += 1
                        live.totalToolCalls += 1
                        live.lastSeenTimestamp = session.timestamp
                    }

                    liveSessions[session.id] = live
                } else {
                    var stats = SessionStats(
                        sessionId: session.id,
                        startedAt: now,
                        lastState: session.state,
                        lastStateChange: now
                    )
                    if session.state == .working, !session.toolName.isEmpty {
                        stats.toolUsage[session.toolName, default: 0] += 1
                        stats.totalToolCalls += 1
                        stats.lastSeenTimestamp = session.timestamp
                    }
                    liveSessions[session.id] = stats

                    var daily = todayEntry()
                    daily.sessionsStarted += 1
                    data.dailyStats[daily.date] = daily
                    dirty = true
                }
            }
        }
    }

    func finalizeSession(_ sessionId: String, at date: Date = Date()) {
        queue.sync {
            _finalizeSession(sessionId, at: date)
        }
    }

    // MARK: - Queries

    func elapsedTime(for sessionId: String) -> TimeInterval? {
        queue.sync {
            guard let live = liveSessions[sessionId] else { return nil }
            return Date().timeIntervalSince(live.startedAt)
        }
    }

    func todayStats() -> DailyStats {
        queue.sync { _todayStats() }
    }

    func recentStats(days: Int) -> [DailyStats] {
        queue.sync { _recentStats(days: days) }
    }

    func topTools(days: Int) -> [(name: String, count: Int)] {
        queue.sync {
            let recent = _recentStats(days: days)
            var combined: [String: Int] = [:]
            for day in recent {
                for (tool, count) in day.toolUsage {
                    combined[tool, default: 0] += count
                }
            }
            return combined.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.map { (name: $0.key, count: $0.value) }
        }
    }

    // MARK: - Persistence

    func save() {
        queue.sync { _save() }
    }

    // MARK: - Internal (must be called while holding `queue`)

    private func _finalizeSession(_ sessionId: String, at date: Date) {
        guard var live = liveSessions.removeValue(forKey: sessionId) else { return }

        let elapsed = date.timeIntervalSince(live.lastStateChange)
        accumulateTime(&live, elapsed: elapsed)

        _flushSessionToDaily(&live, at: date)
        dirty = true
        _save()
    }

    /// Flush accumulated time/tools from a live session into the appropriate daily entry.
    /// Uses the given date to determine which day receives the stats.
    private func _flushSessionToDaily(_ live: inout SessionStats, at date: Date) {
        let key = dateFormatter.string(from: date)
        var daily = data.dailyStats[key] ?? DailyStats(date: key)
        daily.totalWorkingTime += live.workingTime
        daily.totalIdleTime += live.idleTime
        daily.totalToolCalls += live.totalToolCalls
        for (tool, count) in live.toolUsage {
            daily.toolUsage[tool, default: 0] += count
        }
        data.dailyStats[key] = daily

        live.workingTime = 0
        live.idleTime = 0
        live.totalToolCalls = 0
        live.toolUsage = [:]
    }

    private func _todayStats() -> DailyStats {
        var daily = todayEntry()
        for (_, live) in liveSessions {
            let elapsed = Date().timeIntervalSince(live.lastStateChange)
            daily.totalWorkingTime += live.workingTime + (live.lastState == .working ? elapsed : 0)
            daily.totalIdleTime += live.idleTime + (live.lastState == .idle ? elapsed : 0)
            daily.totalToolCalls += live.totalToolCalls
            for (tool, count) in live.toolUsage {
                daily.toolUsage[tool, default: 0] += count
            }
        }
        return daily
    }

    private func _recentStats(days: Int) -> [DailyStats] {
        var result: [DailyStats] = []
        let calendar = Calendar.current
        let today = Date()

        for i in 0..<days {
            guard let date = calendar.date(byAdding: .day, value: -i, to: today) else { continue }
            let key = dateFormatter.string(from: date)
            if i == 0 {
                result.append(_todayStats())
            } else if let stats = data.dailyStats[key] {
                result.append(stats)
            } else {
                result.append(DailyStats(date: key))
            }
        }
        return result
    }

    private func _save() {
        guard dirty else { return }
        pruneOldEntries()

        let fm = FileManager.default
        if !fm.fileExists(atPath: statsDir.path) {
            try? fm.createDirectory(at: statsDir, withIntermediateDirectories: true)
        }

        if let encoded = try? JSONEncoder().encode(data) {
            try? encoded.write(to: statsFile, options: .atomic)
        }
        dirty = false
    }

    // MARK: - Private

    private func load() {
        guard let fileData = try? Data(contentsOf: statsFile),
              let decoded = try? JSONDecoder().decode(StatsData.self, from: fileData) else {
            return
        }
        data = decoded
    }

    private func startAutoSave() {
        saveTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            self.queue.sync {
                self.flushLiveSessionsToDailyStats()
                self._save()
            }
        }
    }

    private func flushLiveSessionsToDailyStats() {
        let now = Date()
        let calendar = Calendar.current

        for (id, var live) in liveSessions {
            // Split time across day boundaries if session spans midnight
            var cursor = live.lastStateChange
            while true {
                let nextMidnight = calendar.nextDate(after: cursor, matching: DateComponents(hour: 0, minute: 0, second: 0), matchingPolicy: .nextTime) ?? now
                if nextMidnight < now {
                    // Accumulate time up to midnight into that day
                    let elapsed = nextMidnight.timeIntervalSince(cursor)
                    accumulateTime(&live, elapsed: elapsed)
                    _flushSessionToDaily(&live, at: cursor)
                    cursor = nextMidnight
                    live.lastStateChange = cursor
                } else {
                    // Remaining time belongs to current day
                    let elapsed = now.timeIntervalSince(cursor)
                    accumulateTime(&live, elapsed: elapsed)
                    _flushSessionToDaily(&live, at: now)
                    live.lastStateChange = now
                    break
                }
            }

            liveSessions[id] = live
        }

        dirty = true
    }

    private func accumulateTime(_ stats: inout SessionStats, elapsed: TimeInterval) {
        guard elapsed > 0 else { return }
        switch stats.lastState {
        case .working: stats.workingTime += elapsed
        case .waiting, .idle: stats.idleTime += elapsed
        }
    }

    private func todayEntry() -> DailyStats {
        let key = dateFormatter.string(from: Date())
        return data.dailyStats[key] ?? DailyStats(date: key)
    }

    private func pruneOldEntries() {
        guard let cutoff = Calendar.current.date(byAdding: .day, value: -30, to: Date()) else { return }
        let cutoffKey = dateFormatter.string(from: cutoff)
        data.dailyStats = data.dailyStats.filter { $0.key >= cutoffKey }
    }
}
