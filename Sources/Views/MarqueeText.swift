import SwiftUI

/// Single-line text that scrolls sideways when it's wider than its space, like a
/// car stereo display. Short text is simply centered and doesn't move.
struct MarqueeText: View {
    let text: String
    var font: Font = .system(size: 11, weight: .medium)
    var isAnimating = true
    /// Points per second.
    var speed: Double = 28
    /// Space between the end of the text and the start of its repeat.
    var gap: CGFloat = 40

    @State private var textWidth: CGFloat = 0

    var body: some View {
        GeometryReader { proxy in
            let overflows = textWidth > proxy.size.width
            TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !(overflows && isAnimating))) { context in
                let cycle = Double(textWidth + gap)
                let offset = overflows
                    ? -(context.date.timeIntervalSinceReferenceDate * speed).truncatingRemainder(dividingBy: cycle)
                    : 0
                // Two copies side by side: when the first scrolls out of view, the
                // second is exactly where the first started, so the loop is seamless.
                HStack(spacing: gap) {
                    label
                    if overflows { label }
                }
                .offset(x: offset)
                .frame(width: proxy.size.width, alignment: overflows ? .leading : .center)
            }
            .frame(height: proxy.size.height)
            .clipped()
            // Fade the edges so text slides in and out instead of being chopped.
            .mask {
                if overflows {
                    LinearGradient(stops: [
                        .init(color: .clear, location: 0),
                        .init(color: .black, location: 0.08),
                        .init(color: .black, location: 0.92),
                        .init(color: .clear, location: 1),
                    ], startPoint: .leading, endPoint: .trailing)
                } else {
                    Color.black
                }
            }
        }
        // Measure the text's natural width with an invisible copy.
        .background {
            label.hidden().background {
                GeometryReader { measure in
                    Color.clear
                        .onAppear { textWidth = measure.size.width }
                        .onChange(of: measure.size.width) { _, width in textWidth = width }
                }
            }
        }
    }

    private var label: some View {
        Text(text)
            .font(font)
            .lineLimit(1)
            .fixedSize()
    }
}
