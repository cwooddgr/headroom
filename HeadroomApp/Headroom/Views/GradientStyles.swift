import SwiftUI

// MARK: - Animated Mesh Gradient Background

struct AnimatedMeshBackground: View {
    @State private var phase: Double = 0

    var body: some View {
        if #available(macOS 26.0, *) {
            meshGradientView
        } else {
            fallbackGradient
        }
    }

    @available(macOS 26.0, *)
    private var meshGradientView: some View {
        SwiftUI.TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate * 0.15

            MeshGradient(
                width: 4, height: 4,
                points: [
                    .init(0, 0), .init(0.33, 0), .init(0.67, 0), .init(1, 0),
                    .init(0, 0.33),
                    .init(Float(0.33 + 0.05 * sin(t * 1.1)), Float(0.33 + 0.05 * cos(t * 0.9))),
                    .init(Float(0.67 + 0.05 * cos(t * 0.8)), Float(0.33 + 0.05 * sin(t * 1.2))),
                    .init(1, 0.33),
                    .init(0, 0.67),
                    .init(Float(0.33 + 0.05 * cos(t * 1.3)), Float(0.67 + 0.05 * sin(t * 0.7))),
                    .init(Float(0.67 + 0.05 * sin(t * 0.9)), Float(0.67 + 0.05 * cos(t * 1.1))),
                    .init(1, 0.67),
                    .init(0, 1), .init(0.33, 1), .init(0.67, 1), .init(1, 1),
                ],
                colors: [
                    Color(hue: 0.70, saturation: 0.9, brightness: 0.10),
                    Color(hue: 0.75, saturation: 0.8, brightness: 0.12),
                    Color(hue: 0.80, saturation: 0.7, brightness: 0.11),
                    Color(hue: 0.85, saturation: 0.8, brightness: 0.09),
                    Color(hue: 0.65, saturation: 0.8, brightness: 0.11),
                    Color(hue: fmod(0.58 + 0.03 * sin(t * 0.4), 1.0), saturation: 0.9, brightness: 0.25),
                    Color(hue: fmod(0.72 + 0.03 * cos(t * 0.5), 1.0), saturation: 0.85, brightness: 0.22),
                    Color(hue: 0.78, saturation: 0.7, brightness: 0.10),
                    Color(hue: 0.55, saturation: 0.7, brightness: 0.10),
                    Color(hue: fmod(0.52 + 0.04 * cos(t * 0.3), 1.0), saturation: 0.85, brightness: 0.22),
                    Color(hue: fmod(0.62 + 0.04 * sin(t * 0.6), 1.0), saturation: 0.9, brightness: 0.28),
                    Color(hue: 0.68, saturation: 0.8, brightness: 0.11),
                    Color(hue: 0.50, saturation: 0.8, brightness: 0.08),
                    Color(hue: 0.55, saturation: 0.7, brightness: 0.10),
                    Color(hue: 0.60, saturation: 0.8, brightness: 0.09),
                    Color(hue: 0.65, saturation: 0.9, brightness: 0.08),
                ]
            )
            .ignoresSafeArea()
        }
    }

    private var fallbackGradient: some View {
        LinearGradient(
            colors: [
                Color(hue: 0.65, saturation: 0.8, brightness: 0.12),
                Color(hue: 0.55, saturation: 0.9, brightness: 0.15),
                Color(hue: 0.70, saturation: 0.7, brightness: 0.10),
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        .ignoresSafeArea()
    }
}

// MARK: - Score Color Helper

func scoreColor(for score: Int) -> Color {
    switch score {
    case 0...2: .green
    case 3...4: .yellow
    case 5...7: .orange
    default: .red
    }
}

func scoreGradient(for score: Int) -> [Color] {
    switch score {
    case 0...2: [.green, .mint]
    case 3...4: [.yellow, .green]
    case 5...7: [.orange, .yellow]
    default: [.red, .orange]
    }
}

// MARK: - Glass Card Modifier

struct GlassCard: ViewModifier {
    var cornerRadius: CGFloat = 20

    func body(content: Content) -> some View {
        let base = content
            .background {
                RoundedRectangle(cornerRadius: cornerRadius)
                    .fill(.ultraThinMaterial)
            }
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
            .shadow(color: .black.opacity(0.15), radius: 12, y: 6)

        if #available(macOS 26.0, *) {
            base.glassEffect(.regular.interactive(), in: .rect(cornerRadius: cornerRadius))
        } else {
            base.overlay {
                RoundedRectangle(cornerRadius: cornerRadius)
                    .strokeBorder(.white.opacity(0.1), lineWidth: 0.5)
            }
        }
    }
}

extension View {
    func glassCard(cornerRadius: CGFloat = 20) -> some View {
        modifier(GlassCard(cornerRadius: cornerRadius))
    }
}

// MARK: - Glass Effect Availability Wrapper

struct GlassEffectModifier: ViewModifier {
    var isSelected: Bool

    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content
                .glassEffect(
                    isSelected ? .regular.interactive() : .clear.interactive(),
                    in: .rect(cornerRadius: 10)
                )
        } else {
            content
        }
    }
}

// MARK: - Glow Effect

struct GlowModifier: ViewModifier {
    let color: Color
    let radius: CGFloat

    func body(content: Content) -> some View {
        content
            .shadow(color: color.opacity(0.6), radius: radius)
            .shadow(color: color.opacity(0.3), radius: radius * 2)
    }
}

extension View {
    func glow(_ color: Color, radius: CGFloat = 8) -> some View {
        modifier(GlowModifier(color: color, radius: radius))
    }
}

// MARK: - Symbol Effect Availability Wrappers

struct BreatheEffectModifier: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 15.0, *) {
            content.symbolEffect(.breathe)
        } else {
            content
        }
    }
}

struct PulseEffectModifier: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 15.0, *) {
            content.symbolEffect(.pulse)
        } else {
            content
        }
    }
}
