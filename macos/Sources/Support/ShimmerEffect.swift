import SwiftUI

private struct ShimmerModifier: ViewModifier {
    let active: Bool
    var duration: Double = 1.5

    @State private var phase: CGFloat = -1

    func body(content: Content) -> some View {
        if active {
            content
                .overlay {
                    GeometryReader { proxy in
                        let width = max(proxy.size.width, 1)
                        LinearGradient(
                            stops: [
                                .init(color: .clear, location: 0.30),
                                .init(color: .white.opacity(0.85), location: 0.50),
                                .init(color: .clear, location: 0.70),
                            ],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                        .frame(width: width)
                        .offset(x: phase * width)
                    }
                    .mask(content)
                    .blendMode(.plusLighter)
                    .allowsHitTesting(false)
                }
                .compositingGroup()
                .onAppear {
                    phase = -1
                    withAnimation(.linear(duration: duration).repeatForever(autoreverses: false)) {
                        phase = 1
                    }
                }
                .onDisappear { phase = -1 }
        } else {
            content
        }
    }
}

extension View {
    func shimmering(active: Bool, duration: Double = 1.5) -> some View {
        modifier(ShimmerModifier(active: active, duration: duration))
    }
}
