import SwiftUI

struct OnboardingView: View {
    @Environment(CollectorManager.self) var collector
    @Environment(HeadroomDatabase.self) var db

    var body: some View {
        VStack(spacing: 32) {
            // Hero
            VStack(spacing: 16) {
                Image(systemName: "waveform.path.ecg.rectangle")
                    .font(.system(size: 56))
                    .foregroundStyle(
                        LinearGradient(colors: [.cyan, .blue], startPoint: .topLeading, endPoint: .bottomTrailing)
                    )
                    .modifier(BreatheEffectModifier())

                Text("Welcome to Headroom")
                    .font(.system(size: 26, weight: .bold, design: .rounded))

                Text("Monitor your Mac's resource usage over time\nand get data-driven purchase recommendations.")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            // Status
            VStack(alignment: .leading, spacing: 12) {
                statusRow(
                    label: "Monitor",
                    detail: collector.statusDescription,
                    ok: collector.isCollecting
                )
                statusRow(
                    label: "Database",
                    detail: collector.dbExists ? "\(db.samples.count) samples" : "Waiting for first sample",
                    ok: collector.dbExists && !db.samples.isEmpty
                )
            }
            .padding(20)
            .frame(maxWidth: 420)
            .glassCard(cornerRadius: 16)

            // Action
            if collector.isPerformingAction {
                VStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.regular)
                    Text("Starting monitor...")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            } else if collector.isCollecting {
                VStack(spacing: 8) {
                    Label("Monitoring Active", systemImage: "checkmark.circle.fill")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.green)

                    if db.samples.isEmpty {
                        Text("Collecting first samples — data will appear shortly.")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                }
            } else {
                Button {
                    collector.start()
                    Task {
                        try? await Task.sleep(for: .seconds(35))
                        db.load()
                    }
                } label: {
                    Label("Start Monitoring", systemImage: "play.fill")
                        .font(.system(size: 15, weight: .semibold))
                        .padding(.horizontal, 24)
                        .padding(.vertical, 10)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderedProminent)
                .tint(.cyan)
            }

            // Status message
            if !collector.statusMessage.isEmpty {
                Text(collector.statusMessage)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: 420)
            }
        }
        .padding(40)
    }

    private func statusRow(label: String, detail: String, ok: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: ok ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(ok ? .green : .orange)
                .font(.system(size: 16))

            VStack(alignment: .leading, spacing: 1) {
                Text(label)
                    .font(.system(size: 13, weight: .semibold))
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
    }
}
