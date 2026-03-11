import SwiftUI

enum ProcessSortMode: String, CaseIterable, Identifiable {
    case memory = "Memory"
    case cpu = "CPU"

    var id: String { rawValue }
}

struct ProcessesView: View {
    @Environment(HeadroomDatabase.self) var db
    @State private var sortMode: ProcessSortMode = .memory

    private var processes: [ProcessInfo] {
        switch sortMode {
        case .memory: db.topProcessesByMemory
        case .cpu: db.topProcessesByCPU
        }
    }

    private var maxValue: Double {
        processes.map { sortMode == .memory ? Double($0.avgMemoryBytes) : $0.avgCpuPct }
            .max() ?? 1
    }

    var body: some View {
        ZStack {
            AnimatedMeshBackground()

            ScrollView {
                VStack(spacing: 20) {
                    // Header
                    HStack {
                        Text("Processes")
                            .font(.system(size: 28, weight: .bold, design: .rounded))
                        Spacer()

                        Picker("Sort", selection: $sortMode) {
                            ForEach(ProcessSortMode.allCases) { mode in
                                Text(mode.rawValue).tag(mode)
                            }
                        }
                        .pickerStyle(.segmented)
                        .frame(width: 180)
                    }

                    if processes.isEmpty {
                        emptyState
                    } else {
                        // Column headers
                        HStack {
                            Text("Process")
                                .frame(width: 180, alignment: .leading)
                            Text(sortMode == .memory ? "Avg Memory" : "Avg CPU")
                                .frame(width: 100, alignment: .trailing)
                            Spacer()
                            Text(sortMode == .memory ? "Avg CPU" : "Max CPU")
                                .frame(width: 80, alignment: .trailing)
                            Text("Seen")
                                .frame(width: 50, alignment: .trailing)
                        }
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .textCase(.uppercase)
                        .tracking(0.5)
                        .padding(.horizontal, 18)

                        // Process rows
                        ForEach(Array(processes.enumerated()), id: \.element.id) { index, process in
                            processRow(process, index: index)
                                .transition(.asymmetric(
                                    insertion: .move(edge: .trailing).combined(with: .opacity),
                                    removal: .move(edge: .leading).combined(with: .opacity)
                                ))
                        }
                    }
                }
                .padding(28)
            }
            .scrollIndicators(.hidden)
        }
        .animation(.spring(duration: 0.4), value: sortMode)
    }

    private func processRow(_ process: ProcessInfo, index: Int) -> some View {
        let relativeValue = sortMode == .memory
            ? Double(process.avgMemoryBytes) / maxValue
            : process.avgCpuPct / maxValue

        let barColor: Color = sortMode == .memory ? .blue : .orange

        return HStack(spacing: 0) {
            // Rank
            Text("\(index + 1)")
                .font(.system(size: 12, weight: .bold, design: .monospaced))
                .foregroundStyle(.tertiary)
                .frame(width: 28)

            // Process name
            Text(process.name)
                .font(.system(size: 13, weight: .medium, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(width: 160, alignment: .leading)

            // Primary value
            Text(sortMode == .memory ? formatBytes(process.avgMemoryBytes) : String(format: "%.1f%%", process.avgCpuPct))
                .font(.system(size: 13, weight: .bold, design: .monospaced))
                .foregroundStyle(barColor)
                .frame(width: 90, alignment: .trailing)

            // Bar
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(barColor.opacity(0.1))

                    Capsule()
                        .fill(
                            LinearGradient(
                                colors: [barColor.opacity(0.8), barColor.opacity(0.4)],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(width: geo.size.width * relativeValue)
                        .glow(barColor, radius: 3)
                }
            }
            .frame(height: 8)
            .padding(.horizontal, 12)

            // Secondary value
            Text(sortMode == .memory ? String(format: "%.1f%%", process.avgCpuPct) : String(format: "%.1f%%", process.maxCpuPct))
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 60, alignment: .trailing)

            // Appearances
            Text("\(process.appearances)")
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundStyle(.tertiary)
                .frame(width: 40, alignment: .trailing)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
        .glassCard(cornerRadius: 12)
    }

    private func formatBytes(_ bytes: Int64) -> String {
        let mb = Double(bytes) / (1024 * 1024)
        if mb >= 1024 {
            return String(format: "%.1f GB", mb / 1024)
        }
        return String(format: "%.0f MB", mb)
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "cpu")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)

            Text("No Process Data")
                .font(.system(size: 22, weight: .bold, design: .rounded))

            Text("Process snapshots are collected every 5 minutes.")
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
        }
        .padding(40)
        .frame(maxWidth: .infinity)
        .glassCard()
    }
}
