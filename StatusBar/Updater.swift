import Foundation
import AppKit

/// Handles checking for updates via GitHub Releases and performing in-place upgrades.
class Updater {
    static let shared = Updater()

    private let repoOwner = "Bkowiec"
    private let repoName = "clawdebar"

    enum Status {
        case upToDate(current: String)
        case available(current: String, latest: String, zipURL: URL)
        case error(String)
    }

    /// Current app version from Info.plist (set at build time).
    var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
    }

    // MARK: - Check

    func check() async -> Status {
        let urlString = "https://api.github.com/repos/\(repoOwner)/\(repoName)/releases/latest"
        guard let url = URL(string: urlString) else {
            return .error("Invalid URL")
        }

        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 15

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            return .error("Network error: \(error.localizedDescription)")
        }

        guard let http = response as? HTTPURLResponse else {
            return .error("Unexpected response")
        }
        guard http.statusCode == 200 else {
            if http.statusCode == 404 {
                return .error("No releases found")
            }
            return .error("GitHub API error (HTTP \(http.statusCode))")
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tagName = json["tag_name"] as? String else {
            return .error("Failed to parse release info")
        }

        let latestVersion = tagName.hasPrefix("v") ? String(tagName.dropFirst()) : tagName

        // Find Clawdebar.zip asset
        guard let assets = json["assets"] as? [[String: Any]],
              let zipAsset = assets.first(where: { ($0["name"] as? String) == "Clawdebar.zip" }),
              let downloadURLString = zipAsset["browser_download_url"] as? String,
              let zipURL = URL(string: downloadURLString) else {
            return .error("Release has no Clawdebar.zip asset")
        }

        if isNewer(latestVersion, than: currentVersion) {
            return .available(current: currentVersion, latest: latestVersion, zipURL: zipURL)
        } else {
            return .upToDate(current: currentVersion)
        }
    }

    // MARK: - Download & Install

    /// Downloads the zip, extracts it, replaces the running app, and relaunches.
    func downloadAndInstall(zipURL: URL) async -> String? {
        let fm = FileManager.default
        let tempDir = fm.temporaryDirectory.appendingPathComponent("clawdebar-update-\(UUID().uuidString)")

        do {
            try fm.createDirectory(at: tempDir, withIntermediateDirectories: true)
        } catch {
            return "Failed to create temp directory: \(error.localizedDescription)"
        }

        defer {
            try? fm.removeItem(at: tempDir)
        }

        // Download
        let zipPath = tempDir.appendingPathComponent("Clawdebar.zip")
        do {
            let (localURL, response) = try await URLSession.shared.download(from: zipURL)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                return "Download failed (non-200 response)"
            }
            try fm.moveItem(at: localURL, to: zipPath)
        } catch {
            return "Download failed: \(error.localizedDescription)"
        }

        // Extract
        let extractDir = tempDir.appendingPathComponent("extracted")
        try? fm.createDirectory(at: extractDir, withIntermediateDirectories: true)

        let ditto = Process()
        ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        ditto.arguments = ["-x", "-k", zipPath.path, extractDir.path]
        ditto.standardError = FileHandle.nullDevice
        do {
            try ditto.run()
            ditto.waitUntilExit()
        } catch {
            return "Failed to extract zip: \(error.localizedDescription)"
        }
        guard ditto.terminationStatus == 0 else {
            return "Extraction failed (exit code \(ditto.terminationStatus))"
        }

        // Find the .app bundle in extracted contents
        let extractedApp = extractDir.appendingPathComponent("Clawdebar.app")
        guard fm.fileExists(atPath: extractedApp.path) else {
            return "Clawdebar.app not found in downloaded archive"
        }

        // Replace current app
        let home = fm.homeDirectoryForCurrentUser.path
        let installedApp = "\(home)/Applications/Clawdebar.app"

        do {
            if fm.fileExists(atPath: installedApp) {
                try fm.removeItem(atPath: installedApp)
            }
            try fm.copyItem(atPath: extractedApp.path, toPath: installedApp)
        } catch {
            return "Failed to replace app: \(error.localizedDescription)"
        }

        // Re-install hooks (the new binary may have updated hook script)
        HookInstaller().installIfNeeded()

        // Relaunch
        relaunch(appPath: installedApp)

        return nil // success
    }

    // MARK: - Version Comparison

    /// Returns true if `a` is semantically newer than `b`.
    private func isNewer(_ a: String, than b: String) -> Bool {
        // "dev" is never up-to-date (always offer update)
        if b == "dev" { return true }
        if a == "dev" { return false }

        let aParts = a.split(separator: ".").compactMap { Int($0) }
        let bParts = b.split(separator: ".").compactMap { Int($0) }

        for i in 0..<max(aParts.count, bParts.count) {
            let av = i < aParts.count ? aParts[i] : 0
            let bv = i < bParts.count ? bParts[i] : 0
            if av > bv { return true }
            if av < bv { return false }
        }
        return false
    }

    // MARK: - Relaunch

    private func relaunch(appPath: String) {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/bash")
        task.arguments = ["-c", "sleep 1 && open \"\(appPath)\""]
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        try? task.run()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            NSApplication.shared.terminate(nil)
        }
    }
}
