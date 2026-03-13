import Foundation
import SQLite3

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

final class CollectionEngine: @unchecked Sendable {
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
            t.schedule(deadline: .now() + 30, repeating: 30, leeway: .seconds(5))
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

        // Process snapshots every 5 minutes (10 x 30s)
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
                    hrLog("\u{1F9F9}", "DB", "Cleaned up \(deleted) bad process snapshot rows")
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

        // Get human-readable model name from system_profiler
        var modelName = model // fallback to hw.model identifier
        let profilerProcess = Foundation.Process()
        profilerProcess.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
        profilerProcess.arguments = ["SPHardwareDataType", "-json"]
        let pipe = Pipe()
        profilerProcess.standardOutput = pipe
        profilerProcess.standardError = Pipe()
        do {
            try profilerProcess.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            profilerProcess.waitUntilExit()
            if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
               let items = json["SPHardwareDataType"] as? [[String: Any]],
               let first = items.first,
               let name = first["machine_name"] as? String {
                if !chip.isEmpty {
                    modelName = "\(name) (\(chip))"
                } else {
                    modelName = name
                }
            }
        } catch {
            hrLog("\u{26A0}\u{FE0F}", "SysInfo", "system_profiler failed: \(error.localizedDescription)")
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
        _ = DatabaseSchema.setSystemInfo(db, key: "model", value: model)
        _ = DatabaseSchema.setSystemInfo(db, key: "model_name", value: modelName)
        _ = DatabaseSchema.setSystemInfo(db, key: "cpu_cores", value: "\(cpuCores)")
        _ = DatabaseSchema.setSystemInfo(db, key: "gpu_cores", value: "\(gpuCores)")
        _ = DatabaseSchema.setSystemInfo(db, key: "total_ram_gb", value: "\(ramGB)")
        _ = DatabaseSchema.setSystemInfo(db, key: "macos_version", value: macOSVersion)
        _ = DatabaseSchema.setSystemInfo(db, key: "perf_cores", value: "\(perfCores)")
        _ = DatabaseSchema.setSystemInfo(db, key: "efficiency_cores", value: "\(effCores)")
    }
}
