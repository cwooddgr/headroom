import Foundation
import SQLite3
import SwiftUI

@MainActor @Observable
final class HeadroomDatabase {
    var samples: [Sample] = []
    var systemInfo: SystemInfoData?
    var topProcessesByMemory: [ProcessInfo] = []
    var topProcessesByCPU: [ProcessInfo] = []
    var analysis: AnalysisResult?
    var isLoaded = false
    var errorMessage: String?

    private let dbPath: String

    init() {
        self.dbPath = HeadroomPaths.databasePath
    }

    func load() {
        guard FileManager.default.fileExists(atPath: dbPath) else {
            errorMessage = nil
            isLoaded = true
            return
        }

        var db: OpaquePointer?
        guard sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            errorMessage = "Failed to open database"
            isLoaded = true
            return
        }
        defer { sqlite3_close(db) }

        systemInfo = querySystemInfo(db!)
        samples = querySamples(db!)
        topProcessesByMemory = queryTopProcesses(db!, orderBy: "avg_mem")
        topProcessesByCPU = queryTopProcesses(db!, orderBy: "avg_cpu")

        if !samples.isEmpty {
            analysis = computeAnalysis(db!)
        }

        isLoaded = true
    }

    // MARK: - Latest values for dashboard

    var latestSample: Sample? { samples.last }

    var recentSamples: [Sample] {
        let cutoff = samples.count > 120 ? samples.count - 120 : 0
        return Array(samples[cutoff...])
    }

    // MARK: - Queries

    private func querySystemInfo(_ db: OpaquePointer) -> SystemInfoData? {
        var info: [String: String] = [:]
        var stmt: OpaquePointer?

        guard sqlite3_prepare_v2(db, "SELECT key, value FROM system_info", -1, &stmt, nil) == SQLITE_OK else {
            return nil
        }
        defer { sqlite3_finalize(stmt) }

        while sqlite3_step(stmt) == SQLITE_ROW {
            let key = String(cString: sqlite3_column_text(stmt, 0))
            let value = String(cString: sqlite3_column_text(stmt, 1))
            info[key] = value
        }

        guard !info.isEmpty else { return nil }

        return SystemInfoData(
            chip: info["chip"] ?? "Unknown",
            model: info["model_name"] ?? info["model"] ?? "Unknown",
            cpuCores: Int(info["cpu_cores"] ?? "0") ?? 0,
            gpuCores: Int(info["gpu_cores"] ?? "0") ?? 0,
            totalRAMGB: Int(info["total_ram_gb"] ?? "0") ?? 0,
            macOSVersion: info["macos_version"] ?? "Unknown"
        )
    }

    private func querySamples(_ db: OpaquePointer) -> [Sample] {
        var stmt: OpaquePointer?
        let sql = """
            SELECT id, timestamp,
                   cpu_e_cluster_pct, cpu_p_cluster_pct, cpu_freq_mhz_e, cpu_freq_mhz_p, cpu_power_watts,
                   gpu_utilization_pct, gpu_freq_mhz, gpu_power_watts, ane_power_watts,
                   memory_swap_used_bytes, memory_pressure, memory_compressed_bytes,
                   memory_pageins, memory_pageouts,
                   thermal_pressure, cpu_temp_avg, gpu_temp_avg,
                   package_power_watts, sys_power_watts
            FROM samples ORDER BY timestamp
            """

        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        let fallbackFormatter = ISO8601DateFormatter()
        fallbackFormatter.formatOptions = [.withInternetDateTime]

        var results: [Sample] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let tsText = columnText(stmt, 1)
            let ts = formatter.date(from: tsText) ?? fallbackFormatter.date(from: tsText) ?? Date()

            results.append(Sample(
                id: Int(sqlite3_column_int(stmt, 0)),
                timestamp: ts,
                cpuEClusterPct: columnDouble(stmt, 2),
                cpuPClusterPct: columnDouble(stmt, 3),
                cpuFreqE: Int(sqlite3_column_int(stmt, 4)),
                cpuFreqP: Int(sqlite3_column_int(stmt, 5)),
                cpuPowerWatts: columnDouble(stmt, 6),
                gpuUtilizationPct: columnDouble(stmt, 7),
                gpuFreqMhz: Int(sqlite3_column_int(stmt, 8)),
                gpuPowerWatts: columnDouble(stmt, 9),
                anePowerWatts: columnDouble(stmt, 10),
                memorySwapUsedBytes: sqlite3_column_int64(stmt, 11),
                memoryPressure: columnText(stmt, 12),
                memoryCompressedBytes: sqlite3_column_int64(stmt, 13),
                memoryPageins: sqlite3_column_int64(stmt, 14),
                memoryPageouts: sqlite3_column_int64(stmt, 15),
                thermalPressure: columnText(stmt, 16),
                cpuTempAvg: columnDouble(stmt, 17),
                gpuTempAvg: columnDouble(stmt, 18),
                packagePowerWatts: columnDouble(stmt, 19),
                sysPowerWatts: columnDouble(stmt, 20)
            ))
        }
        return results
    }

    private func queryTopProcesses(_ db: OpaquePointer, orderBy: String) -> [ProcessInfo] {
        var stmt: OpaquePointer?
        let sql = """
            SELECT process_name, AVG(cpu_pct) as avg_cpu,
                   MAX(cpu_pct) as max_cpu,
                   AVG(memory_bytes) as avg_mem, COUNT(*) as appearances
            FROM process_snapshots
            GROUP BY process_name
            \(orderBy == "avg_cpu" ? "HAVING avg_cpu > 1" : "")
            ORDER BY \(orderBy) DESC LIMIT 15
            """

        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }

        var results: [ProcessInfo] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            results.append(ProcessInfo(
                name: columnText(stmt, 0),
                avgCpuPct: columnDouble(stmt, 1),
                maxCpuPct: columnDouble(stmt, 2),
                avgMemoryBytes: sqlite3_column_int64(stmt, 3),
                appearances: Int(sqlite3_column_int(stmt, 4))
            ))
        }
        return results
    }

    // MARK: - Analysis / Scoring

    private func computeAnalysis(_ db: OpaquePointer) -> AnalysisResult {
        let stats = computeStats(db)

        let memScore = scoreMemory(stats)
        let gpuScore = scoreGPU(stats)
        let cpuScore = scoreCPU(stats)
        let thermalScore = scoreThermal(stats)

        let currentRAM = systemInfo?.totalRAMGB ?? 16

        let scores = [
            DimensionScore(dimension: .memory, score: memScore, recommendation: memoryRecommendation(memScore, currentRAM: currentRAM)),
            DimensionScore(dimension: .gpu, score: gpuScore, recommendation: gpuRecommendation(gpuScore)),
            DimensionScore(dimension: .cpu, score: cpuScore, recommendation: cpuRecommendation(cpuScore)),
            DimensionScore(dimension: .thermal, score: thermalScore, recommendation: thermalRecommendation(thermalScore)),
        ]

        let primary = scores.max(by: { $0.score < $1.score })?.dimension ?? .memory
        let hours = stats.durationHours
        let confidence = hours < 4 ? "Low" : hours < 48 ? "Moderate" : "High"

        return AnalysisResult(
            scores: scores,
            primaryBottleneck: primary,
            confidence: confidence,
            durationHours: hours,
            sampleCount: stats.sampleCount
        )
    }

    // MARK: - Stats

    private struct Stats {
        var sampleCount: Int = 0
        var durationHours: Double = 0
        var swapP90MB: Double = 0
        var pressureWarnPct: Double = 0
        var pressureCriticalPct: Double = 0
        var pageinDeltaP90: Double = 0
        var gpuAbove80: Double = 0
        var gpuAbove90: Double = 0
        var gpuP90: Double = 0
        var gpuPowerP90: Double = 0
        var cpuPAbove80: Double = 0
        var cpuPAbove90: Double = 0
        var cpuP90: Double = 0
        var thermalModeratePct: Double = 0
        var thermalHeavyPct: Double = 0
        var thermalCriticalPct: Double = 0
        var cpuTempP90: Double = 0
    }

    private func computeStats(_ db: OpaquePointer) -> Stats {
        var stats = Stats()
        stats.sampleCount = samples.count

        guard let first = samples.first, let last = samples.last else { return stats }
        stats.durationHours = last.timestamp.timeIntervalSince(first.timestamp) / 3600

        // Swap p90
        let swaps = samples.map { Double($0.memorySwapUsedBytes) / (1024 * 1024) }.sorted()
        stats.swapP90MB = percentile(swaps, 0.9)

        // Memory pressure distribution
        let total = Double(samples.count)
        let warnCount = Double(samples.filter { $0.memoryPressure == "warn" }.count)
        let critCount = Double(samples.filter { $0.memoryPressure == "critical" }.count)
        stats.pressureWarnPct = (warnCount / total) * 100
        stats.pressureCriticalPct = (critCount / total) * 100

        // Page-in deltas
        var deltas: [Double] = []
        for i in 1..<samples.count {
            let d = samples[i].memoryPageins - samples[i-1].memoryPageins
            if d >= 0 { deltas.append(Double(d)) }
        }
        if !deltas.isEmpty {
            deltas.sort()
            stats.pageinDeltaP90 = percentile(deltas, 0.9)
        }

        // GPU
        let gpuUtils = samples.map(\.gpuUtilizationPct)
        stats.gpuAbove80 = (Double(gpuUtils.filter { $0 > 80 }.count) / total) * 100
        stats.gpuAbove90 = (Double(gpuUtils.filter { $0 > 90 }.count) / total) * 100
        stats.gpuP90 = percentile(gpuUtils.sorted(), 0.9)
        stats.gpuPowerP90 = percentile(samples.map(\.gpuPowerWatts).sorted(), 0.9)

        // CPU P-cluster
        let cpuP = samples.map(\.cpuPClusterPct)
        stats.cpuPAbove80 = (Double(cpuP.filter { $0 > 80 }.count) / total) * 100
        stats.cpuPAbove90 = (Double(cpuP.filter { $0 > 90 }.count) / total) * 100
        stats.cpuP90 = percentile(cpuP.sorted(), 0.9)

        // Thermal distribution
        let modCount = Double(samples.filter { $0.thermalPressure == "moderate" }.count)
        let heavyCount = Double(samples.filter { $0.thermalPressure == "heavy" }.count)
        let critThermal = Double(samples.filter { $0.thermalPressure == "critical" }.count)
        stats.thermalModeratePct = (modCount / total) * 100
        stats.thermalHeavyPct = (heavyCount / total) * 100
        stats.thermalCriticalPct = (critThermal / total) * 100
        stats.cpuTempP90 = percentile(samples.map(\.cpuTempAvg).sorted(), 0.9)

        return stats
    }

    private func percentile(_ sorted: [Double], _ p: Double) -> Double {
        guard !sorted.isEmpty else { return 0 }
        let idx = Int(Double(sorted.count) * p)
        return sorted[min(idx, sorted.count - 1)]
    }

    // MARK: - Scoring (ported from Python analyzer)

    private func scoreMemory(_ s: Stats) -> Int {
        var score = 0

        if s.swapP90MB > 8192 { score += 5 }
        else if s.swapP90MB > 4096 { score += 4 }
        else if s.swapP90MB > 1024 { score += 3 }
        else if s.swapP90MB > 256 { score += 2 }
        else if s.swapP90MB > 0 { score += 1 }

        if s.pressureCriticalPct > 5 { score += 3 }
        else if s.pressureCriticalPct > 1 { score += 2 }
        else if s.pressureWarnPct > 20 { score += 2 }
        else if s.pressureWarnPct > 5 { score += 1 }

        if s.pageinDeltaP90 > 10000 { score += 2 }
        else if s.pageinDeltaP90 > 1000 { score += 1 }

        return min(score, 10)
    }

    private func scoreGPU(_ s: Stats) -> Int {
        var score = 0

        if s.gpuAbove90 > 20 { score += 5 }
        else if s.gpuAbove90 > 10 { score += 4 }
        else if s.gpuAbove80 > 20 { score += 3 }
        else if s.gpuAbove80 > 10 { score += 2 }
        else if s.gpuP90 > 50 { score += 1 }

        if s.gpuPowerP90 > 15 { score += 3 }
        else if s.gpuPowerP90 > 8 { score += 2 }
        else if s.gpuPowerP90 > 3 { score += 1 }

        return min(score, 10)
    }

    private func scoreCPU(_ s: Stats) -> Int {
        var score = 0

        if s.cpuPAbove90 > 20 { score += 5 }
        else if s.cpuPAbove90 > 10 { score += 4 }
        else if s.cpuPAbove80 > 20 { score += 3 }
        else if s.cpuPAbove80 > 10 { score += 2 }
        else if s.cpuP90 > 50 { score += 1 }

        let thermalHeavy = s.thermalHeavyPct + s.thermalCriticalPct
        if thermalHeavy > 10 { score += 3 }
        else if thermalHeavy > 5 { score += 2 }
        else if thermalHeavy > 1 { score += 1 }

        return min(score, 10)
    }

    private func scoreThermal(_ s: Stats) -> Int {
        var score = 0

        if s.thermalCriticalPct > 5 { score += 4 }
        else if s.thermalHeavyPct > 10 { score += 3 }
        else if s.thermalHeavyPct > 5 { score += 2 }
        else if s.thermalModeratePct > 30 { score += 2 }
        else if s.thermalModeratePct > 10 { score += 1 }

        if s.cpuTempP90 > 95 { score += 4 }
        else if s.cpuTempP90 > 85 { score += 3 }
        else if s.cpuTempP90 > 75 { score += 1 }

        return min(score, 10)
    }

    // MARK: - Recommendations

    private func memoryRecommendation(_ score: Int, currentRAM: Int) -> String {
        let currentIdx = ramTiers.firstIndex(where: { $0 >= currentRAM }) ?? 0

        switch score {
        case 0...2:
            return "\(currentRAM)GB — current RAM is sufficient"
        case 3...4:
            let bump = min(currentIdx + 1, ramTiers.count - 1)
            return "\(ramTiers[bump])GB (+1 tier)"
        case 5...7:
            let bump = min(currentIdx + 2, ramTiers.count - 1)
            return "\(ramTiers[bump])GB (+2 tiers)"
        default:
            let bump = min(currentIdx + 3, ramTiers.count - 1)
            return "\(ramTiers[bump])GB+ — significant upgrade needed"
        }
    }

    private func gpuRecommendation(_ score: Int) -> String {
        switch score {
        case 0...2: "Base GPU — your GPU workload is light"
        case 3...4: "Base or Pro tier — moderate GPU usage"
        case 5...7: "Pro tier — regular heavy GPU usage"
        default: "Max tier — sustained heavy GPU + bandwidth needs"
        }
    }

    private func cpuRecommendation(_ score: Int) -> String {
        switch score {
        case 0...2: "Base CPU is fine — P-cores rarely saturated"
        case 3...4: "Current tier OK — newer generation would help"
        case 5...7: "Pro tier — more performance cores needed"
        default: "Pro/Max tier — sustained heavy CPU demand"
        }
    }

    private func thermalRecommendation(_ score: Int) -> String {
        switch score {
        case 0...2: "No thermal concerns — any form factor"
        case 3...4: "MacBook Pro preferred over Air for sustained loads"
        case 5...7: "MacBook Pro or desktop Mac recommended"
        default: "Desktop Mac (Mini/Studio/Pro) strongly recommended"
        }
    }

    // MARK: - SQLite Helpers

    private func columnDouble(_ stmt: OpaquePointer?, _ idx: Int32) -> Double {
        sqlite3_column_double(stmt, idx)
    }

    private func columnText(_ stmt: OpaquePointer?, _ idx: Int32) -> String {
        if let text = sqlite3_column_text(stmt, idx) {
            return String(cString: text)
        }
        return ""
    }
}
