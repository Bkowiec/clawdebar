import SwiftUI
import AppKit
import ServiceManagement

@main
struct StatusBarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings {}
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var statusWatcher: StatusWatcher!
    private var sleepManager: SleepManager!
    private var popover: NSPopover!
    private var popoverModel: PopoverViewModel!
    private var animationTimer: Timer?
    private var animationFrame: Int = 0
    private var clickMonitor: Any?
    private let hookInstaller = HookInstaller()

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        // Only register as Login Item when running from an .app bundle
        if #available(macOS 13.0, *), Bundle.main.bundlePath.hasSuffix(".app") {
            try? SMAppService.mainApp.register()
        }

        // Install/update hook script and register in Claude Code settings
        hookInstaller.installIfNeeded()

        sleepManager = SleepManager()

        popoverModel = PopoverViewModel()
        popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(
            rootView: PopoverView(model: popoverModel, onDismiss: { [weak self] in
                self?.closePopover()
            }, onRefresh: { [weak self] in
                self?.refreshSessions()
            })
        )

        statusItem.button?.target = self
        statusItem.button?.action = #selector(statusItemClicked)
        statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])

        statusWatcher = StatusWatcher { [weak self] status in
            DispatchQueue.main.async {
                self?.handleStatusChange(status)
            }
        }

        updateMenuBarButton(for: .idle, sessionCount: 0)

        // Flush stats before system sleep so nothing is lost
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willSleepNotification, object: nil, queue: nil
        ) { [weak self] _ in
            self?.statusWatcher.statsStore.save()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        statusWatcher.statsStore.save()
    }

    func refreshSessions() {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.statusWatcher.discoverRunningSessions()
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.popoverModel.update(from: self.statusWatcher)
            }
        }
    }

    @objc private func statusItemClicked() {
        guard let event = NSApp.currentEvent else { return }
        if event.type == .rightMouseUp {
            let menu = NSMenu()
            menu.addItem(NSMenuItem(title: "Check for Update...", action: #selector(checkForUpdate), keyEquivalent: ""))
            menu.addItem(NSMenuItem.separator())
            menu.addItem(NSMenuItem(title: "Uninstall Clawdebar...", action: #selector(uninstallApp), keyEquivalent: ""))
            menu.addItem(NSMenuItem.separator())
            menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: ""))
            statusItem.menu = menu
            statusItem.button?.performClick(nil)
            statusItem.menu = nil  // reset so left-click works normally next time
        } else {
            togglePopover()
        }
    }

    @objc private func uninstallApp() {
        let alert = NSAlert()
        alert.messageText = "Uninstall Clawdebar?"
        alert.informativeText = "This will remove the hook script, Claude Code hook settings, statistics, and the Login Item. The app bundle must be deleted manually."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Uninstall")
        alert.addButton(withTitle: "Cancel")

        guard alert.runModal() == .alertFirstButtonReturn else { return }

        hookInstaller.uninstall()
        try? FileManager.default.removeItem(atPath: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".clawdebar").path)
        if #available(macOS 13.0, *) {
            try? SMAppService.mainApp.unregister()
        }

        let done = NSAlert()
        done.messageText = "Clawdebar uninstalled"
        done.informativeText = "Hooks and settings have been removed. You can now delete Clawdebar.app from your Applications folder."
        done.runModal()

        NSApplication.shared.terminate(nil)
    }

    @objc private func checkForUpdate() {
        let checking = NSAlert()
        checking.messageText = "Checking for updates..."
        checking.informativeText = "Current version: \(Updater.shared.currentVersion)"
        checking.addButton(withTitle: "Cancel")
        checking.buttons.first?.isHidden = true

        // Show alert and run check concurrently
        Task {
            let result = await Updater.shared.check()

            await MainActor.run {
                // Close the checking alert if still open
                let window = checking.window
                if window.isVisible {
                    window.close()
                    NSApp.stopModal(withCode: .cancel)
                }

                switch result {
                case .upToDate(let current):
                    let alert = NSAlert()
                    alert.messageText = "You're up to date!"
                    alert.informativeText = "Clawdebar \(current) is the latest version."
                    alert.alertStyle = .informational
                    alert.runModal()

                case .available(let current, let latest, let zipURL):
                    let alert = NSAlert()
                    alert.messageText = "Update available"
                    alert.informativeText = "Current: \(current)\nLatest: \(latest)\n\nWould you like to update now?"
                    alert.addButton(withTitle: "Update Now")
                    alert.addButton(withTitle: "Later")

                    guard alert.runModal() == .alertFirstButtonReturn else { return }

                    self.performUpdate(zipURL: zipURL)

                case .error(let message):
                    let alert = NSAlert()
                    alert.messageText = "Update check failed"
                    alert.informativeText = message
                    alert.alertStyle = .warning
                    alert.runModal()
                }
            }
        }

        checking.runModal()
    }

    private func performUpdate(zipURL: URL) {
        let progress = NSAlert()
        progress.messageText = "Downloading update..."
        progress.informativeText = "Please wait while the update is downloaded and installed."
        progress.addButton(withTitle: "OK")
        progress.buttons.first?.isHidden = true

        Task {
            let error = await Updater.shared.downloadAndInstall(zipURL: zipURL)

            await MainActor.run {
                let window = progress.window
                if window.isVisible {
                    window.close()
                    NSApp.stopModal(withCode: .cancel)
                }

                if let error = error {
                    let alert = NSAlert()
                    alert.messageText = "Update failed"
                    alert.informativeText = error
                    alert.alertStyle = .critical
                    alert.runModal()
                }
                // On success, the app will relaunch automatically
            }
        }

        progress.runModal()
    }

    @objc private func togglePopover() {
        if popover.isShown {
            closePopover()
        } else if let button = statusItem.button {
            popoverModel.showStats = false
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
            NSApp.activate(ignoringOtherApps: true)

            clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
                guard let self = self, self.popover.isShown else { return }
                self.closePopover()
            }
        }
    }

    private func closePopover() {
        popover.performClose(nil)
        if let monitor = clickMonitor {
            NSEvent.removeMonitor(monitor)
            clickMonitor = nil
        }
    }

    private func handleStatusChange(_ status: ClaudeStatus) {
        let activeSessions = statusWatcher.sessions.filter { $0.state != .idle }
        updateMenuBarButton(for: status.state, sessionCount: activeSessions.count)
        popoverModel.update(from: statusWatcher)

        switch status.state {
        case .working:
            sleepManager.preventSleep()
            startAnimation(for: .working)
        case .waiting:
            sleepManager.allowSleep()
            startAnimation(for: .waiting)
        case .idle:
            sleepManager.allowSleep()
            stopAnimation()
        }
    }

    private func updateMenuBarButton(for state: ClaudeState, sessionCount: Int) {
        guard let button = statusItem.button else { return }
        button.image = drawClaudeIcon(state: state)
        button.title = sessionCount > 1 ? " \(sessionCount)" : ""
    }

    private func drawClaudeIcon(state: ClaudeState) -> NSImage {
        let s: CGFloat = 18
        let image = NSImage(size: NSSize(width: s, height: s), flipped: true) { rect in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            ctx.clear(rect)

            let color: NSColor
            switch state {
            case .working: color = NSColor(red: 0.80, green: 0.45, blue: 0.30, alpha: 1.0)
            case .waiting: color = NSColor(red: 0.90, green: 0.70, blue: 0.20, alpha: 1.0)
            case .idle:    color = .black
            }

            let u: CGFloat = 1.5

            ctx.setFillColor(color.cgColor)
            ctx.fill(CGRect(x: u*2, y: u*2, width: u*8, height: u*7))
            ctx.fill(CGRect(x: u*1, y: u*1, width: u*2, height: u*2))
            ctx.fill(CGRect(x: u*9, y: u*1, width: u*2, height: u*2))
            ctx.fill(CGRect(x: u*2, y: u*9, width: u*2, height: u*3))
            ctx.fill(CGRect(x: u*8, y: u*9, width: u*2, height: u*3))

            if state != .idle {
                ctx.setLineCap(.round)
                ctx.setLineWidth(1.2)
                ctx.setStrokeColor(NSColor.black.cgColor)

                let ly: CGFloat = u * 5
                let es: CGFloat = u * 1.2

                let lx: CGFloat = u * 4
                ctx.beginPath()
                ctx.move(to: CGPoint(x: lx - es, y: ly - es))
                ctx.addLine(to: CGPoint(x: lx + es * 0.3, y: ly))
                ctx.addLine(to: CGPoint(x: lx - es, y: ly + es))
                ctx.strokePath()

                let rx: CGFloat = u * 8
                ctx.beginPath()
                ctx.move(to: CGPoint(x: rx + es, y: ly - es))
                ctx.addLine(to: CGPoint(x: rx - es * 0.3, y: ly))
                ctx.addLine(to: CGPoint(x: rx + es, y: ly + es))
                ctx.strokePath()
            }

            return true
        }

        image.isTemplate = (state == .idle)
        return image
    }

    private func startAnimation(for state: ClaudeState) {
        stopAnimation()
        animationFrame = 0

        let interval: TimeInterval = state == .working ? 0.05 : 0.1
        animationTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            guard let self = self, let button = self.statusItem.button else { return }
            self.animationFrame += 1

            let alpha: CGFloat
            if state == .working {
                alpha = CGFloat(0.4 + 0.6 * abs(sin(Double(self.animationFrame) * 0.1)))
            } else {
                alpha = self.animationFrame % 10 < 5 ? 1.0 : 0.3
            }
            button.alphaValue = alpha
        }
    }

    private func stopAnimation() {
        animationTimer?.invalidate()
        animationTimer = nil
        animationFrame = 0
        statusItem.button?.alphaValue = 1.0
    }
}

class PopoverViewModel: ObservableObject {
    @Published var aggregatedState: ClaudeState = .idle
    @Published var sessions: [SessionInfo] = []
    @Published var isScanning: Bool = false
    @Published var showStats: Bool = false
    @Published var todayStats: DailyStats = DailyStats(date: "")
    @Published var recentDays: [DailyStats] = []
    @Published var topTools: [(name: String, count: Int)] = []
    @Published var sessionElapsedTimes: [String: TimeInterval] = [:]

    private weak var watcher: StatusWatcher?
    private var refreshTimer: Timer?

    func update(from watcher: StatusWatcher) {
        self.watcher = watcher
        aggregatedState = watcher.aggregatedState
        sessions = watcher.sessions
        isScanning = false
        refreshStats(from: watcher)
        ensureTimer()
    }

    private func refreshStats(from watcher: StatusWatcher) {
        let store = watcher.statsStore
        todayStats = store.todayStats()
        recentDays = store.recentStats(days: 7)
        topTools = store.topTools(days: 7)

        var elapsed: [String: TimeInterval] = [:]
        for session in sessions {
            if let t = store.elapsedTime(for: session.id) {
                elapsed[session.id] = t
            }
        }
        sessionElapsedTimes = elapsed
    }

    private func ensureTimer() {
        if sessions.isEmpty {
            refreshTimer?.invalidate()
            refreshTimer = nil
            return
        }
        guard refreshTimer == nil else { return }
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self = self, let watcher = self.watcher else { return }
            self.refreshStats(from: watcher)
        }
    }
}

struct PopoverView: View {
    @ObservedObject var model: PopoverViewModel
    var onDismiss: (() -> Void)?
    var onRefresh: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Image(systemName: stateIcon)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundColor(stateColor)

                Text(stateTitle)
                    .font(.system(size: 16, weight: .bold))

                Spacer()

                if model.sessions.count > 0 {
                    Text("\(model.sessions.count) session\(model.sessions.count == 1 ? "" : "s")")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(.secondary)
                }
            }
            .padding(16)

            Divider()

            if model.showStats {
                StatsView(
                    todayStats: model.todayStats,
                    recentDays: model.recentDays,
                    topTools: model.topTools
                )
            } else if model.sessions.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "moon.zzz.fill")
                        .font(.system(size: 14))
                        .foregroundColor(.secondary.opacity(0.5))
                    Text("No active sessions")
                        .font(.system(size: 13))
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
            } else {
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(model.sessions) { session in
                            SessionRow(
                                session: session,
                                elapsedTime: model.sessionElapsedTimes[session.id],
                                onActivate: onDismiss
                            )
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                }
                .frame(maxHeight: 300)
                .fixedSize(horizontal: false, vertical: true)
            }

            Divider()

            HStack {
                Button(action: {
                    model.isScanning = true
                    onRefresh?()
                }) {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.clockwise")
                            .rotationEffect(.degrees(model.isScanning ? 360 : 0))
                            .animation(model.isScanning ? .linear(duration: 0.6).repeatForever(autoreverses: false) : .default, value: model.isScanning)
                        Text("Scan processes")
                    }
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .disabled(model.isScanning)

                Spacer()

                Button(action: { model.showStats.toggle() }) {
                    HStack(spacing: 4) {
                        Image(systemName: model.showStats ? "list.bullet" : "chart.bar")
                        Text(model.showStats ? "Sessions" : "Stats")
                    }
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)

            }
            .padding(12)
        }
        .frame(width: 340)
    }

    private var stateIcon: String {
        switch model.aggregatedState {
        case .working: return "sparkle"
        case .waiting: return "exclamationmark.circle.fill"
        case .idle:    return "moon.fill"
        }
    }

    private var stateColor: Color {
        switch model.aggregatedState {
        case .working: return .orange
        case .waiting: return .yellow
        case .idle:    return .gray
        }
    }

    private var stateTitle: String {
        let waitingCount = model.sessions.filter { $0.state == .waiting }.count
        let workingCount = model.sessions.filter { $0.state == .working }.count

        if waitingCount > 0 && workingCount > 0 {
            return "\(waitingCount) waiting, \(workingCount) working"
        } else if waitingCount > 0 {
            return "\(waitingCount) waiting for input"
        } else if workingCount > 0 {
            return "\(workingCount) working"
        }
        return "Idle"
    }
}

struct SessionRow: View {
    let session: SessionInfo
    var elapsedTime: TimeInterval?
    var onActivate: (() -> Void)?

    var body: some View {
        Button(action: focusSession) {
            HStack(spacing: 10) {
                Circle()
                    .fill(sessionColor)
                    .frame(width: 8, height: 8)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(shortenPath(session.workingDirectory))
                            .font(.system(size: 12, weight: .medium))
                            .lineLimit(1)
                            .truncationMode(.head)

                        if !session.app.isEmpty && session.app != "Unknown" {
                            Text(session.app)
                                .font(.system(size: 9, weight: .medium, design: .monospaced))
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(Color.primary.opacity(0.08))
                                .cornerRadius(3)
                        }
                    }

                    HStack(spacing: 4) {
                        Text(sessionStateLabel)
                            .font(.system(size: 11))
                            .foregroundColor(sessionColor)

                        if !session.toolName.isEmpty && session.state == .working {
                            Text("· \(session.toolName)")
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundColor(.secondary)
                        }

                        if let elapsed = elapsedTime {
                            Text("· \(formatDuration(elapsed))")
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundColor(.secondary)
                        }
                    }
                }

                Spacer()

                Image(systemName: "arrow.right.circle")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary.opacity(0.5))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(Color.gray.opacity(0.1))
            .cornerRadius(8)
        }
        .buttonStyle(.plain)
    }

    private var sessionColor: Color {
        switch session.state {
        case .working: return .orange
        case .waiting: return .yellow
        case .idle:    return .gray
        }
    }

    private var sessionStateLabel: String {
        switch session.state {
        case .working: return "Working"
        case .waiting: return "Needs input"
        case .idle:    return "Idle"
        }
    }

    private func shortenPath(_ path: String) -> String {
        if path.isEmpty { return "Unknown" }
        let components = path.split(separator: "/")
        if components.count >= 2 {
            return "…/\(components.suffix(2).joined(separator: "/"))"
        }
        return path.replacingOccurrences(of: NSHomeDirectory(), with: "~")
    }

    private func focusSession() {
        onActivate?()

        let app = session.app
        let dir = session.workingDirectory
        let sessionId = session.id

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            var found = false

            switch app {
            case "VSCode":
                found = self.activateApp(bundleId: "com.microsoft.VSCode")
                if found && !dir.isEmpty {
                    let task = Process()
                    task.executableURL = URL(fileURLWithPath: "/usr/bin/env")
                    task.arguments = ["code", "--goto", dir]
                    try? task.run()
                }

            case "iTerm":
                found = self.activateApp(bundleId: "com.googlecode.iterm2")

            case "Warp":
                found = self.activateApp(bundleId: "dev.warp.Warp-Stable")

            case "kitty":
                found = self.activateApp(name: "kitty")

            case "Alacritty":
                found = self.activateApp(name: "Alacritty")

            case "WezTerm":
                found = self.activateApp(name: "WezTerm")

            case "Terminal":
                found = self.activateApp(bundleId: "com.apple.Terminal")
                if found, let tty = self.sanitizedTty(session.tty) {
                    self.runOsascript("""
                    tell application "Terminal"
                        repeat with w in windows
                            repeat with t in tabs of w
                                if tty of t is "\(tty)" then
                                    set selected of t to true
                                    set miniaturized of w to false
                                    set index of w to 1
                                end if
                            end repeat
                        end repeat
                    end tell
                    """)
                }

            default:
                break
            }

            if !found {
                try? FileManager.default.removeItem(atPath: "/tmp/claude-status-\(sessionId).json")
            }
        }
    }

    private func runOsascript(_ script: String) {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        task.arguments = ["-e", script]
        try? task.run()
    }

    private func sanitizedTty(_ tty: String) -> String? {
        let pattern = #"^/dev/ttys\d+$"#
        guard tty.range(of: pattern, options: .regularExpression) != nil else { return nil }
        return tty
    }

    @discardableResult
    private func activateApp(bundleId: String) -> Bool {
        if let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleId).first {
            app.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
            return true
        }
        return false
    }

    @discardableResult
    private func activateApp(name: String) -> Bool {
        if let app = NSWorkspace.shared.runningApplications.first(where: { $0.localizedName == name }) {
            app.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
            return true
        }
        return false
    }
}

// MARK: - Stats View

struct StatsView: View {
    let todayStats: DailyStats
    let recentDays: [DailyStats]
    let topTools: [(name: String, count: Int)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // Today's summary
                VStack(alignment: .leading, spacing: 8) {
                    Text("Today")
                        .font(.system(size: 13, weight: .semibold))

                    HStack(spacing: 16) {
                        StatBadge(label: "Sessions", value: "\(todayStats.sessionsStarted)", color: .blue)
                        StatBadge(label: "Working", value: formatDuration(todayStats.totalWorkingTime), color: .orange)
                        StatBadge(label: "Tool Calls", value: "\(todayStats.totalToolCalls)", color: .green)
                    }
                }

                if !topTools.isEmpty {
                    Divider()

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Top Tools (7 days)")
                            .font(.system(size: 13, weight: .semibold))

                        let maxCount = topTools.first?.count ?? 1
                        ForEach(topTools.prefix(8), id: \.name) { tool in
                            HStack(spacing: 8) {
                                Text(tool.name)
                                    .font(.system(size: 11, design: .monospaced))
                                    .frame(width: 70, alignment: .trailing)

                                GeometryReader { geo in
                                    RoundedRectangle(cornerRadius: 3)
                                        .fill(Color.orange.opacity(0.7))
                                        .frame(width: geo.size.width * CGFloat(tool.count) / CGFloat(maxCount))
                                }
                                .frame(height: 14)

                                Text("\(tool.count)")
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundColor(.secondary)
                                    .frame(width: 30, alignment: .trailing)
                            }
                        }
                    }
                }

                if recentDays.count > 1 {
                    Divider()

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Last 7 Days")
                            .font(.system(size: 13, weight: .semibold))

                        let maxTime = recentDays.map(\.totalWorkingTime).max() ?? 1

                        ForEach(recentDays, id: \.date) { day in
                            HStack(spacing: 8) {
                                Text(shortDate(day.date))
                                    .font(.system(size: 11, design: .monospaced))
                                    .frame(width: 50, alignment: .trailing)

                                GeometryReader { geo in
                                    let workWidth = maxTime > 0 ? geo.size.width * CGFloat(day.totalWorkingTime / maxTime) : 0

                                    if workWidth > 0 {
                                        RoundedRectangle(cornerRadius: 3)
                                            .fill(Color.orange.opacity(0.7))
                                            .frame(width: workWidth)
                                    }
                                }
                                .frame(height: 14)

                                Text(day.totalWorkingTime > 0 ? formatDuration(day.totalWorkingTime) : "-")
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundColor(.secondary)
                                    .frame(width: 50, alignment: .trailing)
                            }
                        }
                    }
                }
            }
            .padding(16)
        }
        .frame(maxHeight: 350)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func shortDate(_ dateStr: String) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        guard let date = formatter.date(from: dateStr) else { return dateStr }
        let display = DateFormatter()
        display.dateFormat = "MMM d"
        return display.string(from: date)
    }
}

struct StatBadge: View {
    let label: String
    let value: String
    let color: Color

    var body: some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.system(size: 14, weight: .bold, design: .monospaced))
                .foregroundColor(color)
            Text(label)
                .font(.system(size: 10))
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Helpers

private func formatDuration(_ seconds: TimeInterval) -> String {
    let total = Int(seconds)
    if total < 60 { return "\(total)s" }
    let h = total / 3600
    let m = (total % 3600) / 60
    if h > 0 { return "\(h)h \(m)m" }
    return "\(m)m"
}
