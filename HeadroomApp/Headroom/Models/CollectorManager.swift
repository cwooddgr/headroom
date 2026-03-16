import Darwin
import Foundation
@preconcurrency import ServiceManagement
import SQLite3
import SwiftUI

// MARK: - Collection Mode

enum CollectionMode: Equatable {
    case launchAgent
    case inProcess
    case none
}

// MARK: - LaunchAgent Config

private enum LaunchAgentConfig {
    static let label = "co.dgrlabs.headroom.collector"
    static let plistName = "\(label).plist"

    static var plistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents")
            .appendingPathComponent(plistName)
    }

    static var collectorBinaryURL: URL {
        Bundle.main.bundleURL
            .appendingPathComponent("Contents/MacOS/HeadroomCollector")
    }

    static var logPath: String {
        let support = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Headroom")
        return support.appendingPathComponent("collector.log").path
    }
}

// MARK: - Collector Manager (MainActor, Observable)

@MainActor @Observable
final class CollectorManager {
    var isCollecting = false
    var isPerformingAction = false
    var statusMessage = ""
    var sampleCount = 0
    var collectionMode: CollectionMode = .none

    private var engine: CollectionEngine?

    /// Cached result of the last `launchctl list` check, updated by `checkStatus()`.
    private(set) var isLaunchAgentRunning = false

    var dbExists: Bool {
        FileManager.default.fileExists(atPath: HeadroomPaths.databasePath)
    }

    var isLaunchAgentInstalled: Bool {
        FileManager.default.fileExists(atPath: LaunchAgentConfig.plistURL.path)
    }

    /// Runs a Process off the main thread to avoid pumping a nested runloop
    /// during SwiftUI body evaluation (which caused reentrant crashes / SIGSEGV).
    private func runProcess(_ executablePath: String, arguments: [String]) async -> Int32 {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Foundation.Process()
                process.executableURL = URL(fileURLWithPath: executablePath)
                process.arguments = arguments
                process.standardOutput = Pipe()
                process.standardError = Pipe()
                do {
                    try process.run()
                    process.waitUntilExit()
                    continuation.resume(returning: process.terminationStatus)
                } catch {
                    continuation.resume(returning: -1)
                }
            }
        }
    }

    var launchAgentPathMatchesBundle: Bool {
        guard let data = try? Data(contentsOf: LaunchAgentConfig.plistURL),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let args = plist["ProgramArguments"] as? [String],
              let path = args.first else {
            return false
        }
        return path == LaunchAgentConfig.collectorBinaryURL.path
    }

    var isDaemonRunning: Bool {
        isLaunchAgentRunning || isCollecting
    }

    var isFullySetUp: Bool { isDaemonRunning && dbExists }
    var needsSetup: Bool { !isDaemonRunning }

    var statusDescription: String {
        switch collectionMode {
        case .launchAgent: return "Collecting 24/7"
        case .inProcess: return "Collecting (app only)"
        case .none: return "Not started"
        }
    }

    /// Returns true if the app is running from a translocated or read-only location
    /// where LaunchAgent installation would fail or point to a temporary path.
    var isTranslocatedOrReadOnly: Bool {
        let path = Bundle.main.bundlePath
        return path.hasPrefix("/private/var/folders") || path.hasPrefix("/Volumes/")
    }

    // MARK: - Status Check

    func checkStatus() async {
        // Query launchctl off the main thread and cache the result
        isLaunchAgentRunning = await runProcess("/bin/launchctl", arguments: ["list", LaunchAgentConfig.label]) == 0

        // Check if installed plist exists and DB was recently modified
        let newMode: CollectionMode
        if isLaunchAgentInstalled {
            let dbRecentlyModified: Bool = {
                guard let attrs = try? FileManager.default.attributesOfItem(atPath: HeadroomPaths.databasePath),
                      let modDate = attrs[.modificationDate] as? Date else {
                    return false
                }
                return Date().timeIntervalSince(modDate) < 120
            }()

            if dbRecentlyModified || isLaunchAgentRunning {
                newMode = .launchAgent
            } else {
                newMode = .none
            }
        } else if isCollecting {
            newMode = .inProcess
        } else {
            newMode = .none
        }

        if collectionMode != newMode {
            collectionMode = newMode
        }
    }

    // MARK: - LaunchAgent Install/Uninstall

    func installLaunchAgent() async {
        guard !isTranslocatedOrReadOnly else {
            statusMessage = "Move Headroom to /Applications before installing the agent"
            return
        }

        isPerformingAction = true
        statusMessage = ""

        // Stop in-process engine first
        if isCollecting {
            engine?.stop()
            engine = nil
            isCollecting = false
        }

        do {
            // Strip quarantine xattr from the collector binary — launchd refuses
            // to spawn quarantined executables (exit 78) even though they run fine
            // when launched directly. All browser-downloaded DMGs/ZIPs are quarantined.
            let binaryPath = LaunchAgentConfig.collectorBinaryURL.path
            removexattr(binaryPath, "com.apple.quarantine", 0)

            // Ensure ~/Library/LaunchAgents exists
            let launchAgentsDir = LaunchAgentConfig.plistURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: launchAgentsDir, withIntermediateDirectories: true)

            // Build the plist dictionary
            let plist: [String: Any] = [
                "Label": LaunchAgentConfig.label,
                "ProgramArguments": [LaunchAgentConfig.collectorBinaryURL.path],
                "RunAtLoad": true,
                "KeepAlive": true,
                "StandardOutPath": LaunchAgentConfig.logPath,
                "StandardErrorPath": LaunchAgentConfig.logPath,
            ]

            let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            try data.write(to: LaunchAgentConfig.plistURL, options: .atomic)

            // Load via launchctl (off main thread to avoid nested runloop)
            let loadStatus = await runProcess("/bin/launchctl", arguments: ["load", LaunchAgentConfig.plistURL.path])

            if loadStatus == 0 {
                collectionMode = .launchAgent
                statusMessage = "Background agent installed"
            } else {
                statusMessage = "launchctl load failed (exit \(loadStatus))"
            }
        } catch {
            statusMessage = "Failed to install agent: \(error.localizedDescription)"
        }

        isPerformingAction = false
    }

    func uninstallLaunchAgent() async {
        isPerformingAction = true
        statusMessage = ""

        // Unload via launchctl (off main thread to avoid nested runloop)
        if isLaunchAgentInstalled {
            _ = await runProcess("/bin/launchctl", arguments: ["unload", LaunchAgentConfig.plistURL.path])
        }

        // Delete the plist
        try? FileManager.default.removeItem(at: LaunchAgentConfig.plistURL)

        collectionMode = isCollecting ? .inProcess : .none
        statusMessage = "Background agent removed"
        isPerformingAction = false
    }

    // MARK: - Legacy Migration

    /// Clean up any SMAppService registration left by v2.0/2.0.1.
    func migrateLegacyAgent() async {
        // Try to unregister the SMAppService agent from v2.0/2.0.1
        if #available(macOS 13.0, *) {
            do {
                try await SMAppService.agent(plistName: "co.dgrlabs.headroom.collector.plist").unregister()
            } catch {
                // Not registered or already cleaned up — ignore
            }
        }

        // Remove any leftover embedded-style plist that SMAppService may have placed
        let smPlistURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents")
            .appendingPathComponent("co.dgrlabs.headroom.collector.plist")

        // Only remove if it's the old BundleProgram-style plist (not our new ProgramArguments one)
        if let data = try? Data(contentsOf: smPlistURL),
           let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
           plist["BundleProgram"] != nil {
            // Unload first (off main thread to avoid nested runloop)
            _ = await runProcess("/bin/launchctl", arguments: ["unload", smPlistURL.path])
            try? FileManager.default.removeItem(at: smPlistURL)
        }
    }

    // MARK: - In-Process Collection

    func start() {
        guard !isCollecting, !isPerformingAction else { return }

        // Don't start in-process if agent is running
        if isLaunchAgentRunning { return }

        isPerformingAction = true
        statusMessage = ""

        let eng = CollectionEngine { [weak self] count in
            Task { @MainActor [weak self] in
                self?.sampleCount = count
            }
        }
        engine = eng

        eng.start { [weak self] success in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if success {
                    self.isCollecting = true
                    self.collectionMode = .inProcess
                    self.statusMessage = "Monitoring started"
                } else {
                    self.statusMessage = "Failed to start collection"
                    self.engine = nil
                }
                self.isPerformingAction = false
            }
        }
    }

    func stop() {
        engine?.stop()
        engine = nil
        isCollecting = false
        collectionMode = isLaunchAgentRunning ? .launchAgent : .none
        statusMessage = "Monitoring stopped"
    }

    // MARK: - Reset Data

    func resetData() async {
        // Stop in-process engine so it releases the DB
        let wasCollecting = isCollecting
        if isCollecting {
            engine?.stop()
            engine = nil
            isCollecting = false
        }

        // Stop agent so it releases the DB (off main thread to avoid nested runloop)
        let hadAgent = isLaunchAgentInstalled
        if hadAgent {
            _ = await runProcess("/bin/launchctl", arguments: ["unload", LaunchAgentConfig.plistURL.path])
        }

        // Clear data by truncating tables (safe even if a reader has the DB open)
        var db: OpaquePointer?
        if sqlite3_open(HeadroomPaths.databasePath, &db) == SQLITE_OK, let db {
            sqlite3_exec(db, "DELETE FROM samples", nil, nil, nil)
            sqlite3_exec(db, "DELETE FROM process_snapshots", nil, nil, nil)
            sqlite3_exec(db, "DELETE FROM system_info", nil, nil, nil)
            sqlite3_exec(db, "VACUUM", nil, nil, nil)
            sqlite3_close(db)
        }

        // Restart whatever was running
        if hadAgent {
            let loadStatus = await runProcess("/bin/launchctl", arguments: ["load", LaunchAgentConfig.plistURL.path])
            collectionMode = loadStatus == 0 ? .launchAgent : .none
        } else if wasCollecting {
            start()
        } else {
            collectionMode = .none
        }

        sampleCount = 0
        statusMessage = "Data reset"
    }
}
