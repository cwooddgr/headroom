import SwiftUI
import Charts

enum TimelineMetric: String, CaseIterable, Identifiable {
    case cpuP = "CPU P-Cores"
    case cpuE = "CPU E-Cores"
    case gpu = "GPU"
    case swap = "Swap"
    case temperature = "Temperature"
    case power = "Power"

    var id: String { rawValue }

    var unit: String {
        switch self {
        case .cpuP, .cpuE, .gpu: "%"
        case .swap: "MB"
        case .temperature: "°C"
        case .power: "W"
        }
    }

    var color: Color {
        switch self {
        case .cpuP: .orange
        case .cpuE: .cyan
        case .gpu: .green
        case .swap: .blue
        case .temperature: .red
        case .power: .yellow
        }
    }

    var gradient: [Color] {
        switch self {
        case .cpuP: [.orange, .orange.opacity(0)]
        case .cpuE: [.cyan, .cyan.opacity(0)]
        case .gpu: [.green, .green.opacity(0)]
        case .swap: [.blue, .blue.opacity(0)]
        case .temperature: [.red, .red.opacity(0)]
        case .power: [.yellow, .yellow.opacity(0)]
        }
    }
}

enum TimeRange: String, CaseIterable, Identifiable {
    case hour1 = "1H"
    case hour6 = "6H"
    case hour24 = "24H"
    case day7 = "7D"
    case all = "All"

    var id: String { rawValue }

    var seconds: TimeInterval? {
        switch self {
        case .hour1: 3600
        case .hour6: 3600 * 6
        case .hour24: 3600 * 24
        case .day7: 3600 * 24 * 7
        case .all: nil
        }
    }
}

struct MetricsTimelineView: View {
    @Environment(HeadroomDatabase.self) var db
    @State private var selectedMetric: TimelineMetric = .cpuP
    @State private var selectedRange: TimeRange = .all

    private var filteredSamples: [Sample] {
        guard let seconds = selectedRange.seconds, let last = db.samples.last else {
            return db.samples
        }
        let cutoff = last.timestamp.addingTimeInterval(-seconds)
        return db.samples.filter { $0.timestamp >= cutoff }
    }

    var body: some View {
        ZStack {
            AnimatedMeshBackground()

            ScrollView {
                VStack(spacing: 20) {
                    // Header
                    HStack {
                        Text("Timeline")
                            .font(.system(size: 28, weight: .bold, design: .rounded))
                        Spacer()
                    }

                    // Controls
                    HStack(spacing: 16) {
                        // Metric picker
                        HStack(spacing: 4) {
                            ForEach(TimelineMetric.allCases) { metric in
                                Button {
                                    withAnimation(.spring(duration: 0.4)) {
                                        selectedMetric = metric
                                    }
                                } label: {
                                    Text(metric.rawValue)
                                        .font(.system(size: 11, weight: .semibold))
                                        .padding(.horizontal, 10)
                                        .padding(.vertical, 6)
                                        .background(
                                            selectedMetric == metric
                                                ? AnyShapeStyle(metric.color.opacity(0.2))
                                                : AnyShapeStyle(.clear)
                                        )
                                        .foregroundStyle(selectedMetric == metric ? metric.color : .secondary)
                                        .clipShape(Capsule())
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(4)
                        .glassCard(cornerRadius: 16)

                        Spacer()

                        // Time range picker
                        HStack(spacing: 4) {
                            ForEach(TimeRange.allCases) { range in
                                Button {
                                    withAnimation(.spring(duration: 0.4)) {
                                        selectedRange = range
                                    }
                                } label: {
                                    Text(range.rawValue)
                                        .font(.system(size: 11, weight: .semibold))
                                        .padding(.horizontal, 10)
                                        .padding(.vertical, 6)
                                        .background(
                                            selectedRange == range
                                                ? AnyShapeStyle(.white.opacity(0.15))
                                                : AnyShapeStyle(.clear)
                                        )
                                        .foregroundStyle(selectedRange == range ? .primary : .secondary)
                                        .clipShape(Capsule())
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(4)
                        .glassCard(cornerRadius: 16)
                    }

                    // Chart
                    chartView
                        .frame(height: 340)
                        .padding(20)
                        .glassCard()

                    // Stats for selected metric
                    if !filteredSamples.isEmpty {
                        statsRow
                    }
                }
                .padding(28)
            }
            .scrollIndicators(.hidden)
        }
    }

    // MARK: - Chart

    @ViewBuilder
    private var chartView: some View {
        let samples = filteredSamples

        if samples.isEmpty {
            ContentUnavailableView("No data in range", systemImage: "chart.xyaxis.line")
        } else {
            Chart {
                ForEach(downsample(samples, maxPoints: 300), id: \.id) { sample in
                    let value = metricValue(sample)

                    LineMark(
                        x: .value("Time", sample.timestamp),
                        y: .value(selectedMetric.rawValue, value)
                    )
                    .foregroundStyle(selectedMetric.color)
                    .lineStyle(StrokeStyle(lineWidth: 2))
                    .interpolationMethod(.catmullRom)

                    AreaMark(
                        x: .value("Time", sample.timestamp),
                        y: .value(selectedMetric.rawValue, value)
                    )
                    .foregroundStyle(
                        LinearGradient(
                            colors: selectedMetric.gradient,
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .interpolationMethod(.catmullRom)
                }
            }
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: 6)) {
                    AxisValueLabel(format: .dateTime.hour().minute())
                        .foregroundStyle(.secondary)
                    AxisGridLine()
                        .foregroundStyle(.white.opacity(0.05))
                }
            }
            .chartYAxis {
                AxisMarks(position: .leading) {
                    AxisValueLabel()
                        .foregroundStyle(.secondary)
                    AxisGridLine()
                        .foregroundStyle(.white.opacity(0.05))
                }
            }
            .chartYAxisLabel(selectedMetric.unit)
        }
    }

    private func metricValue(_ sample: Sample) -> Double {
        switch selectedMetric {
        case .cpuP: sample.cpuPClusterPct
        case .cpuE: sample.cpuEClusterPct
        case .gpu: sample.gpuUtilizationPct
        case .swap: Double(sample.memorySwapUsedBytes) / (1024 * 1024)
        case .temperature: sample.cpuTempAvg
        case .power: sample.packagePowerWatts
        }
    }

    private func downsample(_ samples: [Sample], maxPoints: Int) -> [Sample] {
        guard samples.count > maxPoints else { return samples }
        let step = samples.count / maxPoints
        return stride(from: 0, to: samples.count, by: step).map { samples[$0] }
    }

    // MARK: - Stats Row

    private var statsRow: some View {
        let values = filteredSamples.map { metricValue($0) }.sorted()
        let count = values.count

        let p50 = values[count / 2]
        let p90 = values[Int(Double(count) * 0.9)]
        let max = values.last ?? 0
        let avg = values.reduce(0, +) / Double(count)

        return HStack(spacing: 12) {
            statPill(label: "Average", value: formatValue(avg))
            statPill(label: "Median", value: formatValue(p50))
            statPill(label: "P90", value: formatValue(p90))
            statPill(label: "Max", value: formatValue(max))
            Spacer()
            Text("\(filteredSamples.count) samples")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.tertiary)
        }
    }

    private func statPill(label: String, value: String) -> some View {
        VStack(spacing: 3) {
            Text(value)
                .font(.system(size: 16, weight: .bold, design: .monospaced))
                .foregroundStyle(selectedMetric.color)
            Text(label)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .glassCard(cornerRadius: 12)
    }

    private func formatValue(_ v: Double) -> String {
        if v >= 1000 {
            return String(format: "%.0f", v)
        } else if v >= 100 {
            return String(format: "%.0f", v)
        } else {
            return String(format: "%.1f", v)
        }
    }
}
