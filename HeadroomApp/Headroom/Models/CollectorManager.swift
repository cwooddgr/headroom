import Foundation
@preconcurrency import ServiceManagement
import SwiftUI

// MARK: - Collection Mode

enum CollectionMode {
    case launchAgent
    case inProcess
    case none
}

// MARK: - Agent Service

@MainActor private let agentService = SMAppService.agent(plistName: "co.dgrlabs.headroom.collector.plist")

// MARK: - Collector Manager (MainActor, Observable)

@MainActor @Observable
final class CollectorManager {
    var isCollecting = false
    var isPerformingAction = false
    var statusMessage = ""
    var sampleCount = 0
    var collectionMode: CollectionMode = .none
    var agentStatus: SMAppService.Status = .notRegistered

    private var engine: CollectionEngine?

    var dbExists: Bool {
        FileManager.default.fileExists(atPath: HeadroomPaths.databasePath)
    }

    var isAgentEnabled: Bool {
        agentStatus == .enabled
    }

    var isAgentRequiresApproval: Bool {
        agentStatus == .requiresApproval
    }

    var isDaemonRunning: Bool {
        isAgentEnabled || isCollecting
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
    /// where SMAppService registration would fail.
    var isTranslocatedOrReadOnly: Bool {
        let path = Bundle.main.bundlePath
        return path.hasPrefix("/private/var/folders") || path.hasPrefix("/Volumes/")
    }

    // MARK: - Status Check

    func checkStatus() {
        agentStatus = agentService.status

        if isAgentEnabled {
            collectionMode = .launchAgent
        } else if isCollecting {
            collectionMode = .inProcess
        } else {
            collectionMode = .none
        }
    }

    // MARK: - Agent Enable/Disable

    func enableAgent() async {
        guard !isTranslocatedOrReadOnly else {
            statusMessage = "Move Headroom to /Applications before enabling the agent"
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
            try agentService.register()
            // SMAppService.status can lag after register(); poll briefly
            for _ in 0..<20 {
                agentStatus = agentService.status
                if isAgentEnabled { break }
                try? await Task.sleep(for: .milliseconds(100))
            }
            if isAgentEnabled {
                collectionMode = .launchAgent
                statusMessage = "Background agent enabled"
            } else if isAgentRequiresApproval {
                statusMessage = "Approve Headroom in System Settings > Login Items"
            }
        } catch {
            statusMessage = "Failed to enable agent: \(error.localizedDescription)"
        }

        isPerformingAction = false
    }

    func disableAgent() async {
        isPerformingAction = true
        statusMessage = ""

        do {
            try await agentService.unregister()
            // SMAppService.status can lag after unregister(); poll briefly
            for _ in 0..<20 {
                agentStatus = agentService.status
                if !isAgentEnabled { break }
                try? await Task.sleep(for: .milliseconds(100))
            }
        } catch {
            statusMessage = "Failed to disable agent: \(error.localizedDescription)"
        }
        collectionMode = isCollecting ? .inProcess : .none
        if statusMessage.isEmpty {
            statusMessage = "Background agent disabled"
        }
        isPerformingAction = false
    }

    // MARK: - Legacy Migration

    /// One-time cleanup of any plist left by the old manual LaunchAgent approach.
    func migrateLegacyAgent() {
        let legacyPlistURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents")
            .appendingPathComponent("co.dgrlabs.headroom.collector.plist")

        guard FileManager.default.fileExists(atPath: legacyPlistURL.path) else { return }

        // Unload the old agent
        let process = Foundation.Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = ["unload", legacyPlistURL.path]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try? process.run()
        process.waitUntilExit()

        // Delete the old plist
        try? FileManager.default.removeItem(at: legacyPlistURL)
    }

    // MARK: - In-Process Collection

    func start() {
        guard !isCollecting, !isPerformingAction else { return }

        // Don't start in-process if agent is running
        if isAgentEnabled { return }

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
        collectionMode = isAgentEnabled ? .launchAgent : .none
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
        let hadAgent = isAgentEnabled
        if hadAgent {
            try? agentService.unregister()
        }

        // Delete the database
        try? FileManager.default.removeItem(atPath: HeadroomPaths.databasePath)
        // Also remove WAL/SHM files
        try? FileManager.default.removeItem(atPath: HeadroomPaths.databasePath + "-wal")
        try? FileManager.default.removeItem(atPath: HeadroomPaths.databasePath + "-shm")

        // Restart whatever was running
        if hadAgent {
            try? agentService.register()
            agentStatus = agentService.status
            collectionMode = isAgentEnabled ? .launchAgent : .none
        } else if wasCollecting {
            start()
        } else {
            collectionMode = .none
        }

        sampleCount = 0
        statusMessage = "Data reset"
    }
}
