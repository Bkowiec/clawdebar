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

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        // Only register as Login Item when running from an .app bundle
        if #available(macOS 13.0, *), Bundle.main.bundlePath.hasSuffix(".app") {
            try? SMAppService.mainApp.register()
        }

        sleepManager = SleepManager()

        popoverModel = PopoverViewModel()
        popover = NSPopover()
        popover.contentSize = NSSize(width: 340, height: 400)
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(
            rootView: PopoverView(model: popoverModel, onDismiss: { [weak self] in
                self?.closePopover()
            })
        )

        statusItem.button?.target = self
        statusItem.button?.action = #selector(togglePopover)

        statusWatcher = StatusWatcher { [weak self] status in
            DispatchQueue.main.async {
                self?.handleStatusChange(status)
            }
        }

        updateMenuBarButton(for: .idle, sessionCount: 0)
    }

    @objc private func togglePopover() {
        if popover.isShown, popover.contentViewController?.view.window?.isOnActiveSpace == true {
            closePopover()
        } else {
            if popover.isShown { closePopover() }

            if let button = statusItem.button {
                popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
                popover.contentViewController?.view.window?.makeKey()
                NSApp.activate(ignoringOtherApps: true)

                clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
                    guard let self = self else { return }
                    if let popoverWindow = self.popover.contentViewController?.view.window,
                       let eventWindow = event.window,
                       popoverWindow == eventWindow { return }
                    self.closePopover()
                }
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

    func update(from watcher: StatusWatcher) {
        aggregatedState = watcher.aggregatedState
        sessions = watcher.sessions
    }
}

struct PopoverView: View {
    @ObservedObject var model: PopoverViewModel
    var onDismiss: (() -> Void)?

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

            if model.sessions.isEmpty {
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
                            SessionRow(session: session, onActivate: onDismiss)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                }
                .frame(maxHeight: 260)
            }

            Divider()

            HStack {
                Spacer()
                Button(action: { NSApplication.shared.terminate(nil) }) {
                    HStack(spacing: 4) {
                        Image(systemName: "xmark.circle")
                        Text("Quit")
                    }
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                Spacer()
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
