import SwiftUI

struct MetricGaugeView: View {
    let dimension: Dimension
    let score: Int
    let subtitle: String
    let value: String

    @State private var animatedProgress: Double = 0
    @State private var appeared = false

    private var progress: Double {
        Double(score) / 10.0
    }

    private var ringColors: [Color] {
        scoreGradient(for: score)
    }

    var body: some View {
        VStack(spacing: 14) {
            ZStack {
                // Background ring
                Circle()
                    .stroke(Color.white.opacity(0.08), lineWidth: 14)

                // Animated score arc
                Circle()
                    .trim(from: 0, to: animatedProgress)
                    .stroke(
                        AngularGradient(
                            gradient: Gradient(colors: ringColors + [ringColors.first!]),
                            center: .center,
                            startAngle: .degrees(-90),
                            endAngle: .degrees(270)
                        ),
                        style: StrokeStyle(lineWidth: 14, lineCap: .round)
                    )
                    .rotationEffect(.degrees(-90))
                    .glow(ringColors.first ?? .blue, radius: animatedProgress > 0 ? 6 : 0)

                // Tick marks
                ForEach(0..<10, id: \.self) { tick in
                    Rectangle()
                        .fill(Color.white.opacity(tick < score ? 0.4 : 0.1))
                        .frame(width: 1.5, height: 6)
                        .offset(y: -58)
                        .rotationEffect(.degrees(Double(tick) * 36))
                }

                // Center content
                VStack(spacing: 2) {
                    Text("\(score)")
                        .font(.system(size: 38, weight: .bold, design: .rounded))
                        .foregroundStyle(
                            LinearGradient(
                                colors: ringColors,
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                        .contentTransition(.numericText())

                    Text("/ 10")
                        .font(.system(size: 13, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 130, height: 130)

            VStack(spacing: 5) {
                HStack(spacing: 6) {
                    Image(systemName: dimension.icon)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(dimension.color)

                    Text(dimension.rawValue)
                        .font(.system(size: 15, weight: .semibold, design: .rounded))
                }

                Text(value)
                    .font(.system(size: 13, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)

                Text(subtitle)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(scoreColor(for: score))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 3)
                    .background(scoreColor(for: score).opacity(0.15), in: Capsule())
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity)
        .glassCard()
        .onAppear {
            guard !appeared else { return }
            appeared = true
            withAnimation(.spring(duration: 1.2, bounce: 0.2).delay(0.1)) {
                animatedProgress = progress
            }
        }
    }
}

// MARK: - Mini Gauge for Recommendation View

struct MiniGaugeView: View {
    let dimension: Dimension
    let score: Int

    @State private var animatedProgress: Double = 0
    @State private var appeared = false

    var body: some View {
        VStack(spacing: 8) {
            ZStack {
                Circle()
                    .stroke(Color.white.opacity(0.08), lineWidth: 8)

                Circle()
                    .trim(from: 0, to: animatedProgress)
                    .stroke(
                        AngularGradient(
                            gradient: Gradient(colors: scoreGradient(for: score)),
                            center: .center,
                            startAngle: .degrees(-90),
                            endAngle: .degrees(270)
                        ),
                        style: StrokeStyle(lineWidth: 8, lineCap: .round)
                    )
                    .rotationEffect(.degrees(-90))
                    .glow(scoreColor(for: score), radius: 4)

                Text("\(score)")
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                    .foregroundStyle(scoreColor(for: score))
                    .contentTransition(.numericText())
            }
            .frame(width: 64, height: 64)

            Text(dimension.rawValue)
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary)
        }
        .onAppear {
            guard !appeared else { return }
            appeared = true
            withAnimation(.spring(duration: 1.0, bounce: 0.2).delay(0.2)) {
                animatedProgress = Double(score) / 10.0
            }
        }
    }
}
