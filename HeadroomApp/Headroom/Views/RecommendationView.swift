import SwiftUI

struct RecommendationView: View {
    @Environment(HeadroomDatabase.self) var db
    @State private var appeared = false

    var body: some View {
        ZStack {
            AnimatedMeshBackground()

            if let analysis = db.analysis {
                ScrollView {
                    VStack(spacing: 28) {
                        headerSection(analysis)
                        heroCard(analysis)
                        scoreRingsRow(analysis)
                        recommendationCards(analysis)
                    }
                    .padding(28)
                }
                .scrollIndicators(.hidden)
            } else {
                emptyState
            }
        }
        .onAppear { appeared = true }
    }

    // MARK: - Header

    private func headerSection(_ analysis: AnalysisResult) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("Recommendation")
                    .font(.system(size: 28, weight: .bold, design: .rounded))

                let hours = analysis.durationHours
                let desc = hours < 1
                    ? "\(Int(hours * 60)) minutes of data"
                    : hours < 48
                        ? String(format: "%.1f hours of data", hours)
                        : String(format: "%.1f days of data", hours / 24)

                Text(desc)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    // MARK: - Hero Card

    private func heroCard(_ analysis: AnalysisResult) -> some View {
        VStack(spacing: 20) {
            // Big score
            let maxScore = analysis.maxScore

            ZStack {
                // Outer glow ring
                Circle()
                    .stroke(scoreColor(for: maxScore).opacity(0.15), lineWidth: 30)
                    .frame(width: 160, height: 160)

                Circle()
                    .trim(from: 0, to: appeared ? Double(maxScore) / 10.0 : 0)
                    .stroke(
                        AngularGradient(
                            gradient: Gradient(colors: scoreGradient(for: maxScore)),
                            center: .center,
                            startAngle: .degrees(-90),
                            endAngle: .degrees(270)
                        ),
                        style: StrokeStyle(lineWidth: 12, lineCap: .round)
                    )
                    .rotationEffect(.degrees(-90))
                    .frame(width: 140, height: 140)
                    .glow(scoreColor(for: maxScore), radius: 10)
                    .animation(.spring(duration: 1.5, bounce: 0.2), value: appeared)

                VStack(spacing: 0) {
                    Text("\(maxScore)")
                        .font(.system(size: 52, weight: .heavy, design: .rounded))
                        .foregroundStyle(
                            LinearGradient(
                                colors: scoreGradient(for: maxScore),
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )

                    Text("peak score")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }

            // Bottleneck callout
            if maxScore > 2 {
                VStack(spacing: 6) {
                    Text("Primary Bottleneck")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                        .textCase(.uppercase)
                        .tracking(1.5)

                    Text(analysis.primaryBottleneck.rawValue)
                        .font(.system(size: 24, weight: .bold, design: .rounded))
                        .foregroundStyle(analysis.primaryBottleneck.color)
                }
            } else {
                VStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 28))
                        .foregroundStyle(.green)

                    Text("Your Mac is well-matched to your workload")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }

            // Confidence
            HStack(spacing: 6) {
                Image(systemName: "chart.bar.fill")
                    .font(.system(size: 11))
                Text("\(analysis.confidence) confidence")
                    .font(.system(size: 12, weight: .medium))
                Text("·")
                Text("\(analysis.sampleCount) samples")
                    .font(.system(size: 12, weight: .medium))
            }
            .foregroundStyle(.tertiary)
        }
        .padding(32)
        .frame(maxWidth: .infinity)
        .glassCard()
    }

    // MARK: - Score Rings Row

    private func scoreRingsRow(_ analysis: AnalysisResult) -> some View {
        HStack(spacing: 24) {
            ForEach(analysis.scores) { score in
                MiniGaugeView(dimension: score.dimension, score: score.score)
            }
        }
        .padding(.vertical, 8)
    }

    // MARK: - Recommendation Cards

    private func recommendationCards(_ analysis: AnalysisResult) -> some View {
        VStack(spacing: 12) {
            ForEach(analysis.scores) { score in
                HStack(spacing: 16) {
                    Image(systemName: score.dimension.icon)
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(score.dimension.color)
                        .frame(width: 36, height: 36)
                        .background(score.dimension.color.opacity(0.15))
                        .clipShape(RoundedRectangle(cornerRadius: 10))

                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Text(score.dimension.rawValue)
                                .font(.system(size: 14, weight: .semibold, design: .rounded))

                            Text("\(score.score)/10")
                                .font(.system(size: 12, weight: .bold, design: .monospaced))
                                .foregroundStyle(scoreColor(for: score.score))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(scoreColor(for: score.score).opacity(0.15), in: Capsule())
                        }

                        Text(score.recommendation)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.secondary)
                    }

                    Spacer()
                }
                .padding(16)
                .glassCard(cornerRadius: 16)
            }
        }
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "star.circle")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
                .modifier(PulseEffectModifier())

            Text("No Analysis Available")
                .font(.system(size: 22, weight: .bold, design: .rounded))

            Text("Start monitoring to collect data.")
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
        }
        .padding(40)
        .glassCard()
    }
}
