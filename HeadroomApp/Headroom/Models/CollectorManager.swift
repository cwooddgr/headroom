import Foundation
import SwiftUI

// MARK: - Collection Mode

enum CollectionMode {
    case launchAgent
    case inProcess
    case none
}

// MARK: - LaunchAgent Configuration

private enum LaunchAgentConfig {
    static let label = "co.dgrlabs.headroom.collector"

    static var plistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents")
            .appendingPathComponent("\(label).plist")
    }

    static var collectorBinaryURL: URL? {
        Bundle.main.executableURL?.deletingLastPathComponent()
            .appendingPathComponent("HeadroomCollector")
    }

    static var logPath: String {
        HeadroomPaths.databaseDirectory
            .appendingPathComponent("collector.log").path
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
    var isLaunchAgentInstalled = false
    var isLaunchAgentRunning = false

    private var engine: CollectionEngine?

    var dbExists: Bool {
        FileManager.default.fileExists(atPath: HeadroomPaths.databasePath)
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

    var launchAgentPathMatchesBundle: Bool {
        guard let bundleBinary = LaunchAgentConfig.collectorBinaryURL else { return false }
        let plistURL = LaunchAgentConfig.plistURL
        guard FileManager.default.fileExists(atPath: plistURL.path),
              let data = try? Data(contentsOf: plistURL),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let args = plist["ProgramArguments"] as? [String],
              let installedPath = args.first else {
            return false
        }
        return installedPath == bundleBinary.path
    }

    // MARK: - Status Check

    func checkStatus() {
        let plistExists = FileManager.default.fileExists(atPath: LaunchAgentConfig.plistURL.path)
        isLaunchAgentInstalled = plistExists

        if plistExists {
            let process = Foundation.Process()
            process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
            process.arguments = ["list", LaunchAgentConfig.label]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = Pipe()
            do {
                try process.run()
                process.waitUntilExit()
                isLaunchAgentRunning = process.terminationStatus == 0
            } catch {
                isLaunchAgentRunning = false
            }
        } else {
            isLaunchAgentRunning = false
        }

        if isLaunchAgentRunning {
            collectionMode = .launchAgent
        } else if isCollecting {
            collectionMode = .inProcess
        } else {
            collectionMode = .none
        }
    }

    // MARK: - LaunchAgent Install/Uninstall

    func installLaunchAgent() {
        guard let binaryURL = LaunchAgentConfig.collectorBinaryURL,
              FileManager.default.fileExists(atPath: binaryURL.path) else {
            statusMessage = "HeadroomCollector binary not found in app bundle"
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

        // Ensure LaunchAgents directory exists
        let launchAgentsDir = LaunchAgentConfig.plistURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: launchAgentsDir, withIntermediateDirectories: true)

        // Ensure log directory exists
        try? FileManager.default.createDirectory(
            at: HeadroomPaths.databaseDirectory,
            withIntermediateDirectories: true
        )

        // Generate plist
        let plist: [String: Any] = [
            "Label": LaunchAgentConfig.label,
            "ProgramArguments": [binaryURL.path],
            "RunAtLoad": true,
            "KeepAlive": true,
            "StandardOutPath": LaunchAgentConfig.logPath,
            "StandardErrorPath": LaunchAgentConfig.logPath,
            "ProcessType": "Background",
        ]

        do {
            let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            try data.write(to: LaunchAgentConfig.plistURL)
        } catch {
            statusMessage = "Failed to write plist: \(error.localizedDescription)"
            isPerformingAction = false
            return
        }

        // Load the agent
        let process = Foundation.Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = ["load", LaunchAgentConfig.plistURL.path]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
            if process.terminationStatus == 0 {
                isLaunchAgentInstalled = true
                isLaunchAgentRunning = true
                collectionMode = .launchAgent
                statusMessage = "Background agent installed"
            } else {
                statusMessage = "launchctl load failed (exit \(process.terminationStatus))"
            }
        } catch {
            statusMessage = "Failed to run launchctl: \(error.localizedDescription)"
        }

        isPerformingAction = false
    }

    func uninstallLaunchAgent() {
        isPerformingAction = true
        statusMessage = ""

        let plistURL = LaunchAgentConfig.plistURL

        // Unload first
        if isLaunchAgentRunning {
            let process = Foundation.Process()
            process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
            process.arguments = ["unload", plistURL.path]
            process.standardOutput = Pipe()
            process.standardError = Pipe()
            do {
                try process.run()
                process.waitUntilExit()
            } catch {
                // Continue to delete plist anyway
            }
        }

        // Delete plist
        try? FileManager.default.removeItem(at: plistURL)

        isLaunchAgentInstalled = false
        isLaunchAgentRunning = false
        collectionMode = isCollecting ? .inProcess : .none
        statusMessage = "Background agent removed"
        isPerformingAction = false
    }

    // MARK: - In-Process Collection

    func start() {
        guard !isCollecting, !isPerformingAction else { return }

        // Don't start in-process if LaunchAgent is running
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
}
