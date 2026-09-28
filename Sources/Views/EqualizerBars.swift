import SwiftUI

/// Fake "now playing" bars. They aren't driven by real audio levels (Spotify
/// doesn't expose any), just a smooth pseudo-random motion.
struct EqualizerBars: View {
    var isAnimating: Bool
    var barCount = 4
    var color = Color(red: 0.12, green: 0.84, blue: 0.38)   // Spotify green

    var body: some View {
        // TimelineView re-renders every display frame while not paused, like a
        // requestAnimationFrame loop. Paused, it costs nothing.
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !isAnimating)) { context in
            let time = context.date.timeIntervalSinceReferenceDate
            GeometryReader { proxy in
                let barWidth = proxy.size.width / (CGFloat(barCount) * 1.6)
                HStack(alignment: .center, spacing: (proxy.size.width - barWidth * CGFloat(barCount)) / CGFloat(barCount - 1)) {
                    ForEach(0..<barCount, id: \.self) { index in
                        Capsule()
                            .fill(color)
                            .frame(width: barWidth, height: max(barWidth, proxy.size.height * level(index, at: time)))
                    }
                }
                .frame(width: proxy.size.width, height: proxy.size.height)
            }
        }
        .animation(.easeOut(duration: 0.3), value: isAnimating)
    }

    /// 0...1 height for a bar. Two sine waves per bar at unrelated speeds, so no
    /// two bars move in sync and the pattern doesn't visibly repeat.
    private func level(_ index: Int, at time: TimeInterval) -> CGFloat {
        guard isAnimating else { return 0.25 }
        let speeds: [Double] = [7.3, 5.1, 8.7, 6.2]
        let phase = Double(index) * 1.9
        let a = sin(time * speeds[index % speeds.count] + phase)
        let b = sin(time * speeds[(index + 2) % speeds.count] * 0.53 + phase * 0.7)
        let value = (a + b) / 4 + 0.5        // -2...2 → 0...1
        return 0.3 + 0.7 * CGFloat(value)
    }
}
