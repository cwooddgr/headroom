import SwiftUI

enum Tab: String, CaseIterable, Identifiable, Hashable {
    case dashboard = "Dashboard"
    case timeline = "Timeline"
    case processes = "Processes"
    case recommendation = "Recommendation"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .dashboard: "gauge.with.dots.needle.67percent"
        case .timeline: "chart.xyaxis.line"
        case .recommendation: "star.circle.fill"
        case .processes: "cpu"
        }
    }
}

struct ContentView: View {
    @Environment(HeadroomDatabase.self) var db
    @Environment(CollectorManager.self) var collector
    @State private var selectedTab: Tab = .dashboard

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            detailView
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .task {
            collector.checkStatus()
            db.load()
        }
        .task(id: "refresh") {
            // Auto-refresh every 30 seconds
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                collector.checkStatus()
                db.load()
            }
        }
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        VStack(spacing: 0) {
            // Navigation tabs
            VStack(alignment: .leading, spacing: 4) {
                // Data tabs
                ForEach([Tab.dashboard, .timeline, .processes], id: \.self) { tab in
                    sidebarButton(for: tab)
                }

                Divider()
                    .padding(.vertical, 4)
                    .opacity(0.3)

                // Hero destination
                sidebarButton(for: .recommendation)
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)

            Spacer()

            Divider()
                .padding(.horizontal, 14)
                .opacity(0.3)

            // Collector status section
            collectorStatusSection
                .padding(.horizontal, 14)
                .padding(.vertical, 10)

            // System info
            if let info = db.systemInfo {
                VStack(alignment: .leading, spacing: 2) {
                    Text(info.chip)
                        .font(.system(size: 11, weight: .semibold))
                    Text("\(info.totalRAMGB) GB · macOS \(info.macOSVersion)")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 10)
            }
        }
        .frame(width: 190)
        .background(.ultraThinMaterial)
    }

    // MARK: - Sidebar Button

    private func sidebarButton(for tab: Tab) -> some View {
        let isSelected = selectedTab == tab
        return Button {
            withAnimation(.spring(duration: 0.35)) {
                selectedTab = tab
            }
        } label: {
            Label(tab.rawValue, systemImage: tab.icon)
                .font(.system(size: 13, weight: isSelected ? .semibold : .medium))
                .foregroundStyle(isSelected ? .primary : .secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .contentShape(Rectangle())
                .background {
                    if isSelected {
                        RoundedRectangle(cornerRadius: 10)
                            .fill(.ultraThinMaterial)
                    }
                }
                .overlay {
                    if isSelected {
                        RoundedRectangle(cornerRadius: 10)
                            .strokeBorder(.white.opacity(0.15), lineWidth: 0.5)
                    }
                }
        }
        .buttonStyle(.plain)
        .modifier(GlassEffectModifier(isSelected: isSelected))
    }

    // MARK: - Collector Status

    private var collectorStatusSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Circle()
                    .fill(statusDotColor)
                    .frame(width: 7, height: 7)

                Text(collector.statusDescription)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(collector.isDaemonRunning ? .primary : .secondary)

                Spacer()
            }

            if db.isLoaded {
                Text("\(db.samples.count) samples")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }

            // Path mismatch warning
            if collector.isLaunchAgentInstalled && !collector.launchAgentPathMatchesBundle {
                Button {
                    collector.uninstallLaunchAgent()
                    collector.installLaunchAgent()
                } label: {
                    Label("Reinstall (app moved)", systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.orange)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 3)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            // Action buttons
            if collector.isPerformingAction {
                HStack(spacing: 4) {
                    ProgressView()
                        .controlSize(.mini)
                    Text("Working...")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
            } else {
                switch collector.collectionMode {
                case .launchAgent:
                    Button {
                        collector.uninstallLaunchAgent()
                    } label: {
                        Label("Remove Agent", systemImage: "xmark.circle")
                            .font(.system(size: 11, weight: .medium))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 5)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                case .inProcess:
                    Button {
                        collector.installLaunchAgent()
                    } label: {
                        Label("Install Background Agent", systemImage: "arrow.clockwise.circle")
                            .font(.system(size: 11, weight: .medium))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 5)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.cyan)
                    .controlSize(.small)

                    Button {
                        collector.stop()
                    } label: {
                        Label("Pause", systemImage: "pause.fill")
                            .font(.system(size: 11, weight: .medium))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 5)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                case .none:
                    Button {
                        collector.installLaunchAgent()
                    } label: {
                        Label("Install Background Agent", systemImage: "arrow.clockwise.circle")
                            .font(.system(size: 11, weight: .medium))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 5)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.cyan)
                    .controlSize(.small)

                    Button {
                        collector.start()
                        Task {
                            try? await Task.sleep(for: .seconds(35))
                            db.load()
                        }
                    } label: {
                        Label("Start In-App Only", systemImage: "play.fill")
                            .font(.system(size: 11, weight: .medium))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 5)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
        }
    }

    private var statusDotColor: Color {
        switch collector.collectionMode {
        case .launchAgent: .green
        case .inProcess: .yellow
        case .none: .red
        }
    }

    // MARK: - Detail

    @ViewBuilder
    private var detailView: some View {
        switch selectedTab {
        case .dashboard:
            DashboardView()
        case .timeline:
            MetricsTimelineView()
        case .recommendation:
            RecommendationView()
        case .processes:
            ProcessesView()
        }
    }
}
