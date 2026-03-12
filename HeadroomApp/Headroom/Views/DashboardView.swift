import SwiftUI

struct DashboardView: View {
    @Environment(HeadroomDatabase.self) var db
    @State private var showConfidenceTooltip = false

    var body: some View {
        ZStack {
            AnimatedMeshBackground()

            if let analysis = db.analysis {
                ScrollView {
                    VStack(spacing: 24) {
                        headerSection

                        gaugeGrid(analysis)

                        pressureLegend

                        if let latest = db.latestSample {
                            liveMetricsSection(latest)
                        }

                        if let info = db.systemInfo {
                            systemInfoBar(info, analysis: analysis)
                        }
                    }
                    .padding(28)
                }
                .scrollIndicators(.hidden)
            } else {
                emptyState
            }
        }
    }

    // MARK: - Header

    private var headerSection: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("Dashboard")
                    .font(.system(size: 28, weight: .bold, design: .rounded))

                if let analysis = db.analysis {
                    Text("\(analysis.sampleCount) samples collected")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            Button {
                db.load()
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 14, weight: .semibold))
            }
            .buttonStyle(.plain)
            .padding(10)
            .glassCard(cornerRadius: 12)
        }
    }

    // MARK: - Gauge Grid

    private func gaugeGrid(_ analysis: AnalysisResult) -> some View {
        let columns = [
            GridItem(.flexible(), spacing: 16),
            GridItem(.flexible(), spacing: 16),
        ]

        return LazyVGrid(columns: columns, spacing: 16) {
            ForEach(analysis.scores) { score in
                MetricGaugeView(
                    dimension: score.dimension,
                    score: score.score,
                    subtitle: score.status,
                    value: currentValue(for: score.dimension)
                )
            }
        }
    }

    private var pressureLegend: some View {
        HStack(spacing: 4) {
            Image(systemName: "info.circle")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
            Text("Pressure scores: 0 = no stress, 10 = severe bottleneck. Hover over a gauge for details.")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.tertiary)
        }
    }

    private func currentValue(for dimension: Dimension) -> String {
        guard let s = db.latestSample else { return "—" }
        switch dimension {
        case .memory:
            let swapMB = Double(s.memorySwapUsedBytes) / (1024 * 1024)
            if swapMB > 1024 {
                return String(format: "%.1f GB swap", swapMB / 1024)
            }
            return String(format: "%.0f MB swap", swapMB)
        case .gpu:
            return String(format: "%.0f%% utilization", s.gpuUtilizationPct)
        case .cpu:
            return String(format: "%.0f%% P-cores", s.cpuPClusterPct)
        case .thermal:
            return String(format: "%.0f°C", s.cpuTempAvg)
        }
    }

    // MARK: - Live Metrics

    private func liveMetricsSection(_ sample: Sample) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Latest Reading")
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .foregroundStyle(.secondary)

            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 4), spacing: 12) {
                liveMetricPill(label: "Package", value: String(format: "%.1fW", sample.packagePowerWatts), icon: "bolt.fill", color: .yellow)
                liveMetricPill(label: "E-Cores", value: String(format: "%.0f%%", sample.cpuEClusterPct), icon: "cpu", color: .cyan)
                liveMetricPill(label: "GPU Temp", value: String(format: "%.0f°C", sample.gpuTempAvg), icon: "thermometer.low", color: .orange)
                liveMetricPill(label: "Pressure", value: sample.memoryPressure.capitalized, icon: "gauge.with.dots.needle.bottom.50percent", color: pressureColor(sample.memoryPressure))
            }
        }
    }

    private func liveMetricPill(label: String, value: String, icon: String, color: Color) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(color)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 2) {
                Text(value)
                    .font(.system(size: 14, weight: .bold, design: .monospaced))
                Text(label)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .glassCard(cornerRadius: 14)
    }

    private func pressureColor(_ pressure: String) -> Color {
        switch pressure {
        case "warn": .yellow
        case "critical": .red
        default: .green
        }
    }

    // MARK: - System Info Bar

    private func systemInfoBar(_ info: SystemInfoData, analysis: AnalysisResult) -> some View {
        HStack(spacing: 16) {
            Label(info.model, systemImage: "laptopcomputer")
            Divider().frame(height: 16)
            Label(info.chip, systemImage: "cpu")
            Divider().frame(height: 16)
            Label("\(info.totalRAMGB) GB", systemImage: "memorychip")
            Divider().frame(height: 16)
            Label("macOS \(info.macOSVersion)", systemImage: "apple.logo")

            Spacer()

            HStack(spacing: 6) {
                Circle()
                    .fill(analysis.confidence == "High" ? .green : analysis.confidence == "Moderate" ? .yellow : .orange)
                    .frame(width: 8, height: 8)
                Text("\(analysis.confidence) confidence")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            .onHover { hovering in
                showConfidenceTooltip = hovering
            }
            .popover(isPresented: $showConfidenceTooltip, arrowEdge: .bottom) {
                Text(confidenceTooltip(for: analysis.confidence))
                    .font(.system(size: 11))
                    .padding(8)
            }
        }
        .font(.system(size: 12, weight: .medium, design: .rounded))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .glassCard(cornerRadius: 14)
    }

    private func confidenceTooltip(for confidence: String) -> String {
        switch confidence {
        case "High":
            return "48+ hours of data collected. Recommendations reflect your real workload patterns."
        case "Moderate":
            return "4–48 hours of data collected. Recommendations are becoming reliable."
        default:
            return "Less than 4 hours of data collected. Keep monitoring for more accurate recommendations."
        }
    }

    // MARK: - Empty State / Onboarding

    private var emptyState: some View {
        OnboardingView()
    }
}
