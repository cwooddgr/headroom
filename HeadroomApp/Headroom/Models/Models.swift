import SwiftUI

// MARK: - Sample

struct Sample: Identifiable {
    let id: Int
    let timestamp: Date
    let cpuEClusterPct: Double
    let cpuPClusterPct: Double
    let cpuFreqE: Int
    let cpuFreqP: Int
    let cpuPowerWatts: Double
    let gpuUtilizationPct: Double
    let gpuFreqMhz: Int
    let gpuPowerWatts: Double
    let anePowerWatts: Double
    let memorySwapUsedBytes: Int64
    let memoryPressure: String
    let memoryCompressedBytes: Int64
    let memoryPageins: Int64
    let memoryPageouts: Int64
    let thermalPressure: String
    let cpuTempAvg: Double
    let gpuTempAvg: Double
    let packagePowerWatts: Double
    let sysPowerWatts: Double
}

// MARK: - System Info

struct SystemInfoData {
    let chip: String
    let model: String
    let cpuCores: Int
    let gpuCores: Int
    let totalRAMGB: Int
    let macOSVersion: String
}

// MARK: - Process Info (aggregated)

struct ProcessInfo: Identifiable {
    let id = UUID()
    let name: String
    let avgCpuPct: Double
    let maxCpuPct: Double
    let avgMemoryBytes: Int64
    let appearances: Int
}

// MARK: - Percentile Stats

struct PercentileStats {
    let p50: Double
    let p90: Double
    let p99: Double
    let min: Double
    let max: Double
    let avg: Double

    static let zero = PercentileStats(p50: 0, p90: 0, p99: 0, min: 0, max: 0, avg: 0)
}

// MARK: - Dimension

enum Dimension: String, CaseIterable, Identifiable {
    case memory = "Memory"
    case gpu = "GPU"
    case cpu = "CPU"
    case thermal = "Thermal"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .memory: "memorychip"
        case .gpu: "rectangle.3.group"
        case .cpu: "cpu"
        case .thermal: "thermometer.medium"
        }
    }

    var gradient: [Color] {
        switch self {
        case .memory: [.blue, .cyan]
        case .gpu: [.green, .mint]
        case .cpu: [.orange, .yellow]
        case .thermal: [.red, .pink]
        }
    }

    var color: Color {
        switch self {
        case .memory: .blue
        case .gpu: .green
        case .cpu: .orange
        case .thermal: .red
        }
    }
}

// MARK: - Dimension Score

struct DimensionScore: Identifiable {
    let dimension: Dimension
    let score: Int
    let recommendation: String

    var id: String { dimension.rawValue }

    var status: String {
        switch score {
        case 0...2: "OK"
        case 3...4: "Watch"
        case 5...7: "Constrained"
        default: "Critical"
        }
    }

    var statusColor: Color {
        switch score {
        case 0...2: .green
        case 3...4: .yellow
        case 5...7: .orange
        default: .red
        }
    }
}

// MARK: - Analysis Result

struct AnalysisResult {
    let scores: [DimensionScore]
    let primaryBottleneck: Dimension
    let confidence: String
    let durationHours: Double
    let sampleCount: Int

    var maxScore: Int {
        scores.map(\.score).max() ?? 0
    }
}

// MARK: - RAM Tiers

let ramTiers: [Int] = [8, 16, 24, 32, 48, 64, 96, 128]
