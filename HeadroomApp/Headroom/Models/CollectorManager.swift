import Darwin
import Foundation
@preconcurrency import ServiceManagement
import SwiftUI

// MARK: - Collection Mode

enum CollectionMode {
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

    var dbExists: Bool {
        FileManager.default.fileExists(atPath: HeadroomPaths.databasePath)
    }

    var isLaunchAgentInstalled: Bool {
        FileManager.default.fileExists(atPath: LaunchAgentConfig.plistURL.path)
    }

    var isLaunchAgentRunning: Bool {
        // Check if launchctl knows about the agent and it has a PID
        let process = Foundation.Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = ["list", LaunchAgentConfig.label]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
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

    func checkStatus() {
        // Check if installed plist exists and DB was recently modified
        if isLaunchAgentInstalled {
            let dbRecentlyModified: Bool = {
                guard let attrs = try? FileManager.default.attributesOfItem(atPath: HeadroomPaths.databasePath),
                      let modDate = attrs[.modificationDate] as? Date else {
                    return false
                }
                return Date().timeIntervalSince(modDate) < 120
            }()

            if dbRecentlyModified || isLaunchAgentRunning {
                collectionMode = .launchAgent
            } else {
                collectionMode = .none
            }
        } else if isCollecting {
            collectionMode = .inProcess
        } else {
            collectionMode = .none
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

            // Load via launchctl
            let process = Foundation.Process()
            process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
            process.arguments = ["load", LaunchAgentConfig.plistURL.path]
            process.standardOutput = Pipe()
            process.standardError = Pipe()
            try process.run()
            process.waitUntilExit()

            if process.terminationStatus == 0 {
                collectionMode = .launchAgent
                statusMessage = "Background agent installed"
            } else {
                statusMessage = "launchctl load failed (exit \(process.terminationStatus))"
            }
        } catch {
            statusMessage = "Failed to install agent: \(error.localizedDescription)"
        }

        isPerformingAction = false
    }

    func uninstallLaunchAgent() async {
        isPerformingAction = true
        statusMessage = ""

        // Unload via launchctl
        if isLaunchAgentInstalled {
            let process = Foundation.Process()
            process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
            process.arguments = ["unload", LaunchAgentConfig.plistURL.path]
            process.standardOutput = Pipe()
            process.standardError = Pipe()
            try? process.run()
            process.waitUntilExit()
        }

        // Delete the plist
        try? FileManager.default.removeItem(at: LaunchAgentConfig.plistURL)

        collectionMode = isCollecting ? .inProcess : .none
        statusMessage = "Background agent removed"
        isPerformingAction = false
    }

    // MARK: - Legacy Migration

    /// Clean up any SMAppService registration left by v2.0/2.0.1.
    func migrateLegacyAgent() {
        // Try to unregister the SMAppService agent from v2.0/2.0.1
        if #available(macOS 13.0, *) {
            do {
                try SMAppService.agent(plistName: "co.dgrlabs.headroom.collector.plist").unregister()
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
            // Unload first
            let process = Foundation.Process()
            process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
            process.arguments = ["unload", smPlistURL.path]
            process.standardOutput = Pipe()
            process.standardError = Pipe()
            try? process.run()
            process.waitUntilExit()

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

    func resetData() {
        // Stop in-process engine so it releases the DB
        let wasCollecting = isCollecting
        if isCollecting {
            engine?.stop()
            engine = nil
            isCollecting = false
        }

        // Stop agent so it releases the DB
        let hadAgent = isLaunchAgentInstalled
        if hadAgent {
            let process = Foundation.Process()
            process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
            process.arguments = ["unload", LaunchAgentConfig.plistURL.path]
            process.standardOutput = Pipe()
            process.standardError = Pipe()
            try? process.run()
            process.waitUntilExit()
        }

        // Delete the database
        try? FileManager.default.removeItem(atPath: HeadroomPaths.databasePath)
        // Also remove WAL/SHM files
        try? FileManager.default.removeItem(atPath: HeadroomPaths.databasePath + "-wal")
        try? FileManager.default.removeItem(atPath: HeadroomPaths.databasePath + "-shm")

        // Restart whatever was running
        if hadAgent {
            let process = Foundation.Process()
            process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
            process.arguments = ["load", LaunchAgentConfig.plistURL.path]
            process.standardOutput = Pipe()
            process.standardError = Pipe()
            try? process.run()
            process.waitUntilExit()
            collectionMode = isLaunchAgentRunning ? .launchAgent : .none
        } else if wasCollecting {
            start()
        } else {
            collectionMode = .none
        }

        sampleCount = 0
        statusMessage = "Data reset"
    }
}
