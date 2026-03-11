import Foundation
import SQLite3
import SwiftUI

// MARK: - Database Path

enum HeadroomPaths {
    static let databaseDirectory: URL = {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first!
        return appSupport.appendingPathComponent("Headroom")
    }()

    static let databaseURL = databaseDirectory.appendingPathComponent("headroom.db")
    static var databasePath: String { databaseURL.path }
}

// MARK: - Background Collection Engine

private final class CollectionEngine: @unchecked Sendable {
    private let queue = DispatchQueue(label: "co.dgrlabs.headroom.collector")
    private var metricsCollector: MetricsCollector?
    private var processSnapshotCollector: ProcessSnapshot?
    private var db: OpaquePointer?
    private var timer: DispatchSourceTimer?
    private var sampleCount = 0
    private let processSnapshotInterval = 10 // every 10 samples = 5 minutes

    let onSampleCollected: @Sendable (Int) -> Void

    init(onSampleCollected: @escaping @Sendable (Int) -> Void) {
        self.onSampleCollected = onSampleCollected
    }

    func start(completion: @escaping @Sendable (Bool) -> Void) {
        queue.async { [self] in
            // Ensure directory exists
            try? FileManager.default.createDirectory(
                at: HeadroomPaths.databaseDirectory,
                withIntermediateDirectories: true
            )

            // Open database
            var dbPtr: OpaquePointer?
            guard sqlite3_open(HeadroomPaths.databasePath, &dbPtr) == SQLITE_OK,
                  let dbPtr else {
                completion(false)
                return
            }

            DatabaseSchema.enableWAL(dbPtr)
            guard DatabaseSchema.createTables(dbPtr) else {
                sqlite3_close(dbPtr)
                completion(false)
                return
            }

            // One-time cleanup: delete process snapshots with bogus CPU percentages
            // (from before the delta-based CPU calculation fix)
            Self.cleanupBadProcessData(dbPtr)

            db = dbPtr
            collectSystemInfo(dbPtr)

            let mc = MetricsCollector()
            let ps = ProcessSnapshot()
            metricsCollector = mc
            processSnapshotCollector = ps

            // IOReport needs two samples for delta — take baseline
            _ = mc.collectSample()
            sampleCount = 0

            // Start 30-second collection timer
            let t = DispatchSource.makeTimerSource(queue: queue)
            t.schedule(deadline: .now() + 30, repeating: 30)
            t.setEventHandler { [weak self] in
                self?.tick()
            }
            timer = t
            t.resume()

            completion(true)
        }
    }

    func stop() {
        queue.sync {
            timer?.cancel()
            timer = nil
            metricsCollector = nil
            processSnapshotCollector = nil
            if let db {
                sqlite3_close(db)
                self.db = nil
            }
        }
    }

    private func tick() {
        guard let db, let mc = metricsCollector else { return }

        let sample = mc.collectSample()
        let timestamp = Self.currentTimestamp()

        let inserted = DatabaseSchema.insertSample(
            db,
            timestamp: timestamp,
            cpuEClusterPct: sample.cpuEClusterPct,
            cpuPClusterPct: sample.cpuPClusterPct,
            cpuFreqE: sample.cpuFreqE,
            cpuFreqP: sample.cpuFreqP,
            cpuPowerWatts: sample.cpuPowerWatts,
            gpuUtilizationPct: sample.gpuUtilizationPct,
            gpuFreqMhz: sample.gpuFreqMhz,
            gpuPowerWatts: sample.gpuPowerWatts,
            anePowerWatts: sample.anePowerWatts,
            memorySwapUsedBytes: sample.memorySwapUsedBytes,
            memoryPressure: sample.memoryPressure,
            memoryCompressedBytes: sample.memoryCompressedBytes,
            memoryPageins: sample.memoryPageins,
            memoryPageouts: sample.memoryPageouts,
            thermalPressure: sample.thermalPressure,
            cpuTempAvg: sample.cpuTempAvg,
            gpuTempAvg: sample.gpuTempAvg,
            packagePowerWatts: sample.packagePowerWatts,
            sysPowerWatts: sample.sysPowerWatts
        )

        if inserted {
            sampleCount += 1
            onSampleCollected(sampleCount)
        }

        // Process snapshots every 5 minutes (10 × 30s)
        if sampleCount > 0 && sampleCount % processSnapshotInterval == 0 {
            if let ps = processSnapshotCollector {
                let processes = ps.captureTopProcesses()
                let procs = processes.map {
                    (pid: $0.pid, name: $0.name, cpuPct: $0.cpuPct, memoryBytes: $0.memoryBytes)
                }
                _ = DatabaseSchema.insertProcessSnapshots(db, timestamp: timestamp, processes: procs)
            }
        }
    }

    private static func currentTimestamp() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: Date())
    }

    // MARK: - Data Cleanup

    private static func cleanupBadProcessData(_ db: OpaquePointer) {
        // Delete process snapshots with CPU > 1000% (physically impossible, from old buggy calculation)
        var stmt: OpaquePointer?
        let sql = "DELETE FROM process_snapshots WHERE cpu_pct > 1000"
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            if sqlite3_step(stmt) == SQLITE_DONE {
                let deleted = sqlite3_changes(db)
                if deleted > 0 {
                    print("CollectionEngine: cleaned up \(deleted) bad process snapshot rows")
                }
            }
        }
        sqlite3_finalize(stmt)
    }

    // MARK: - System Info Collection

    private func collectSystemInfo(_ db: OpaquePointer) {
        var stmt: OpaquePointer?
        sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM system_info", -1, &stmt, nil)
        var count: Int32 = 0
        if sqlite3_step(stmt) == SQLITE_ROW {
            count = sqlite3_column_int(stmt, 0)
        }
        sqlite3_finalize(stmt)
        guard count == 0 else { return }

        var chip = ""
        var size = 0
        sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0)
        if size > 0 {
            var buffer = [CChar](repeating: 0, count: size)
            sysctlbyname("machdep.cpu.brand_string", &buffer, &size, nil, 0)
            chip = String(cString: buffer)
        }
        if chip.isEmpty {
            size = 0
            sysctlbyname("hw.chip", nil, &size, nil, 0)
            if size > 0 {
                var buffer = [CChar](repeating: 0, count: size)
                sysctlbyname("hw.chip", &buffer, &size, nil, 0)
                chip = String(cString: buffer)
            }
        }

        var model = ""
        size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        if size > 0 {
            var buffer = [CChar](repeating: 0, count: size)
            sysctlbyname("hw.model", &buffer, &size, nil, 0)
            model = String(cString: buffer)
        }

        var cpuCores: Int32 = 0
        size = MemoryLayout<Int32>.size
        sysctlbyname("hw.ncpu", &cpuCores, &size, nil, 0)

        var perfCores: Int32 = 0
        size = MemoryLayout<Int32>.size
        sysctlbyname("hw.perflevel0.logicalcpu", &perfCores, &size, nil, 0)

        var effCores: Int32 = 0
        size = MemoryLayout<Int32>.size
        sysctlbyname("hw.perflevel1.logicalcpu", &effCores, &size, nil, 0)

        var gpuCores: Int32 = 0
        size = MemoryLayout<Int32>.size
        sysctlbyname("machdep.gpu.core_count", &gpuCores, &size, nil, 0)

        var ramBytes: UInt64 = 0
        size = MemoryLayout<UInt64>.size
        sysctlbyname("hw.memsize", &ramBytes, &size, nil, 0)
        let ramGB = Int(ramBytes / (1024 * 1024 * 1024))

        let osVersion = Foundation.ProcessInfo.processInfo.operatingSystemVersion
        let macOSVersion = "\(osVersion.majorVersion).\(osVersion.minorVersion).\(osVersion.patchVersion)"

        _ = DatabaseSchema.setSystemInfo(db, key: "chip", value: chip)
        _ = DatabaseSchema.setSystemInfo(db, key: "model_name", value: model)
        _ = DatabaseSchema.setSystemInfo(db, key: "cpu_cores", value: "\(cpuCores)")
        _ = DatabaseSchema.setSystemInfo(db, key: "gpu_cores", value: "\(gpuCores)")
        _ = DatabaseSchema.setSystemInfo(db, key: "total_ram_gb", value: "\(ramGB)")
        _ = DatabaseSchema.setSystemInfo(db, key: "macos_version", value: macOSVersion)
        _ = DatabaseSchema.setSystemInfo(db, key: "perf_cores", value: "\(perfCores)")
        _ = DatabaseSchema.setSystemInfo(db, key: "efficiency_cores", value: "\(effCores)")
    }
}

// MARK: - Collector Manager (MainActor, Observable)

@MainActor @Observable
final class CollectorManager {
    var isCollecting = false
    var isPerformingAction = false
    var statusMessage = ""
    var sampleCount = 0

    private var engine: CollectionEngine?

    var dbExists: Bool {
        FileManager.default.fileExists(atPath: HeadroomPaths.databasePath)
    }

    var isDaemonRunning: Bool { isCollecting }
    var isFullySetUp: Bool { isCollecting && dbExists }
    var needsSetup: Bool { !isCollecting }

    var statusDescription: String {
        isCollecting ? "Running" : "Not started"
    }

    func checkStatus() {
        // In single-process mode, state is always current
    }

    func start() {
        guard !isCollecting, !isPerformingAction else { return }
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
        statusMessage = "Monitoring stopped"
    }
}
