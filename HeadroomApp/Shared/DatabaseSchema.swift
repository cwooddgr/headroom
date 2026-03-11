import Foundation
import SQLite3

enum DatabaseSchema {
    static func createTables(_ db: OpaquePointer) -> Bool {
        let statements = [
            """
            CREATE TABLE IF NOT EXISTS samples (
                id INTEGER PRIMARY KEY,
                timestamp TEXT NOT NULL,
                cpu_e_cluster_pct REAL,
                cpu_p_cluster_pct REAL,
                cpu_freq_mhz_e INTEGER,
                cpu_freq_mhz_p INTEGER,
                cpu_power_watts REAL,
                gpu_utilization_pct REAL,
                gpu_freq_mhz INTEGER,
                gpu_power_watts REAL,
                ane_power_watts REAL,
                memory_swap_used_bytes INTEGER,
                memory_pressure TEXT,
                memory_compressed_bytes INTEGER,
                memory_pageins INTEGER,
                memory_pageouts INTEGER,
                thermal_pressure TEXT,
                cpu_temp_avg REAL,
                gpu_temp_avg REAL,
                package_power_watts REAL,
                sys_power_watts REAL
            )
            """,
            "CREATE INDEX IF NOT EXISTS idx_samples_timestamp ON samples(timestamp)",
            """
            CREATE TABLE IF NOT EXISTS process_snapshots (
                id INTEGER PRIMARY KEY,
                timestamp TEXT NOT NULL,
                pid INTEGER,
                process_name TEXT,
                cpu_pct REAL,
                memory_bytes INTEGER
            )
            """,
            "CREATE INDEX IF NOT EXISTS idx_snapshots_timestamp ON process_snapshots(timestamp)",
            """
            CREATE TABLE IF NOT EXISTS system_info (
                key TEXT PRIMARY KEY,
                value TEXT
            )
            """,
        ]

        for sql in statements {
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                let err = String(cString: sqlite3_errmsg(db))
                print("Schema prepare error: \(err)")
                return false
            }
            guard sqlite3_step(stmt) == SQLITE_DONE else {
                let err = String(cString: sqlite3_errmsg(db))
                sqlite3_finalize(stmt)
                print("Schema step error: \(err)")
                return false
            }
            sqlite3_finalize(stmt)
        }
        return true
    }

    static func enableWAL(_ db: OpaquePointer) {
        var stmt: OpaquePointer?
        sqlite3_prepare_v2(db, "PRAGMA journal_mode=WAL", -1, &stmt, nil)
        sqlite3_step(stmt)
        sqlite3_finalize(stmt)
    }

    static func insertSample(
        _ db: OpaquePointer,
        timestamp: String,
        cpuEClusterPct: Double,
        cpuPClusterPct: Double,
        cpuFreqE: Int,
        cpuFreqP: Int,
        cpuPowerWatts: Double,
        gpuUtilizationPct: Double,
        gpuFreqMhz: Int,
        gpuPowerWatts: Double,
        anePowerWatts: Double,
        memorySwapUsedBytes: Int64,
        memoryPressure: String,
        memoryCompressedBytes: Int64,
        memoryPageins: Int64,
        memoryPageouts: Int64,
        thermalPressure: String,
        cpuTempAvg: Double,
        gpuTempAvg: Double,
        packagePowerWatts: Double,
        sysPowerWatts: Double
    ) -> Bool {
        let sql = """
            INSERT INTO samples (
                timestamp, cpu_e_cluster_pct, cpu_p_cluster_pct,
                cpu_freq_mhz_e, cpu_freq_mhz_p, cpu_power_watts,
                gpu_utilization_pct, gpu_freq_mhz, gpu_power_watts, ane_power_watts,
                memory_swap_used_bytes, memory_pressure, memory_compressed_bytes,
                memory_pageins, memory_pageouts,
                thermal_pressure, cpu_temp_avg, gpu_temp_avg,
                package_power_watts, sys_power_watts
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return false }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, (timestamp as NSString).utf8String, -1, nil)
        sqlite3_bind_double(stmt, 2, cpuEClusterPct)
        sqlite3_bind_double(stmt, 3, cpuPClusterPct)
        sqlite3_bind_int(stmt, 4, Int32(cpuFreqE))
        sqlite3_bind_int(stmt, 5, Int32(cpuFreqP))
        sqlite3_bind_double(stmt, 6, cpuPowerWatts)
        sqlite3_bind_double(stmt, 7, gpuUtilizationPct)
        sqlite3_bind_int(stmt, 8, Int32(gpuFreqMhz))
        sqlite3_bind_double(stmt, 9, gpuPowerWatts)
        sqlite3_bind_double(stmt, 10, anePowerWatts)
        sqlite3_bind_int64(stmt, 11, memorySwapUsedBytes)
        sqlite3_bind_text(stmt, 12, (memoryPressure as NSString).utf8String, -1, nil)
        sqlite3_bind_int64(stmt, 13, memoryCompressedBytes)
        sqlite3_bind_int64(stmt, 14, memoryPageins)
        sqlite3_bind_int64(stmt, 15, memoryPageouts)
        sqlite3_bind_text(stmt, 16, (thermalPressure as NSString).utf8String, -1, nil)
        sqlite3_bind_double(stmt, 17, cpuTempAvg)
        sqlite3_bind_double(stmt, 18, gpuTempAvg)
        sqlite3_bind_double(stmt, 19, packagePowerWatts)
        sqlite3_bind_double(stmt, 20, sysPowerWatts)

        return sqlite3_step(stmt) == SQLITE_DONE
    }

    static func insertProcessSnapshots(
        _ db: OpaquePointer,
        timestamp: String,
        processes: [(pid: Int32, name: String, cpuPct: Double, memoryBytes: Int64)]
    ) -> Bool {
        let sql = """
            INSERT INTO process_snapshots (timestamp, pid, process_name, cpu_pct, memory_bytes)
            VALUES (?, ?, ?, ?, ?)
            """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return false }
        defer { sqlite3_finalize(stmt) }

        for proc in processes {
            sqlite3_reset(stmt)
            sqlite3_bind_text(stmt, 1, (timestamp as NSString).utf8String, -1, nil)
            sqlite3_bind_int(stmt, 2, proc.pid)
            sqlite3_bind_text(stmt, 3, (proc.name as NSString).utf8String, -1, nil)
            sqlite3_bind_double(stmt, 4, proc.cpuPct)
            sqlite3_bind_int64(stmt, 5, proc.memoryBytes)
            if sqlite3_step(stmt) != SQLITE_DONE {
                return false
            }
        }
        return true
    }

    static func setSystemInfo(_ db: OpaquePointer, key: String, value: String) -> Bool {
        let sql = "INSERT OR REPLACE INTO system_info (key, value) VALUES (?, ?)"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return false }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, (key as NSString).utf8String, -1, nil)
        sqlite3_bind_text(stmt, 2, (value as NSString).utf8String, -1, nil)
        return sqlite3_step(stmt) == SQLITE_DONE
    }
}
