import SwiftUI

/// The hovered state: artwork, title/artist, progress and transport controls,
/// or a hint when Spotify isn't available.
struct ExpandedView: View {
    @ObservedObject var spotify: SpotifyController
    @ObservedObject var queue: QueueController
    let queueLayout: NotchGeometry.QueueLayout
    let geometry: NotchGeometry

    var body: some View {
        let size = geometry.shapeSize(.expanded(queueLayout))

        VStack(spacing: 0) {
            // Space hidden behind the physical camera housing.
            Color.clear.frame(height: geometry.contentTopInset)
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.horizontal, 22)
                .padding(.top, 10)
                .padding(.bottom, 16)
                .frame(height: NotchGeometry.playerHeight)
            QueueView(queue: queue, layout: queueLayout, geometry: geometry)
        }
        .frame(width: size.width, height: size.height)
        .foregroundStyle(.white)
    }

    @ViewBuilder
    private var content: some View {
        switch spotify.status {
        case .notInstalled:
            HintView(symbol: "exclamationmark.circle", message: "Spotify isn't installed")
        case .notRunning:
            HintView(symbol: "moon.zzz", message: "Spotify isn't running",
                     actionTitle: "Open Spotify", action: spotify.openSpotify)
        case .ready, .permissionDenied:
            if let track = spotify.track {
                player(track)
            } else if spotify.status == .permissionDenied {
                permissionHint
            } else {
                HintView(symbol: "music.note", message: "Nothing playing")
            }
        }
    }

    private func player(_ track: SpotifyTrack) -> some View {
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                ArtworkView(image: spotify.artwork, cornerRadius: 8)
                    .frame(width: 52, height: 52)
                VStack(alignment: .leading, spacing: 3) {
                    Text(track.name)
                        .font(.system(size: 14, weight: .semibold))
                        .lineLimit(1)
                    Text(track.artist)
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.6))
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                EqualizerBars(isAnimating: spotify.isPlaying)
                    .frame(width: 18, height: 16)
                ControlButton(symbol: "arrow.up.forward.app", size: 14, action: spotify.openSpotify)
                    .help("Open Spotify")
            }

            // Seeking needs AppleScript, so only when Automation access is granted.
            ProgressRow(spotify: spotify, duration: track.duration, canSeek: spotify.status == .ready)

            if spotify.status == .permissionDenied {
                permissionHint
            } else {
                controls
            }
        }
    }

    private var controls: some View {
        HStack(spacing: 36) {
            ControlButton(symbol: "backward.fill", size: 16, action: spotify.previousTrack)
            ControlButton(symbol: spotify.isPlaying ? "pause.fill" : "play.fill", size: 22, action: spotify.playPause)
            ControlButton(symbol: "forward.fill", size: 16, action: spotify.nextTrack)
        }
    }

    private var permissionHint: some View {
        HintView(symbol: "lock",
                 message: "Allow NotchPlayer to control Spotify in Privacy & Security → Automation",
                 actionTitle: "Open Settings",
                 action: spotify.openAutomationSettings,
                 compact: true)
    }
}

private struct ControlButton: View {
    let symbol: String
    let size: CGFloat
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .semibold))
                .frame(width: 32, height: 28)
                // Without this only the glyph's opaque pixels are clickable.
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(isHovered ? 1 : 0.85)
        .scaleEffect(isHovered ? 1.1 : 1)
        .animation(.easeOut(duration: 0.12), value: isHovered)
        .onHover { isHovered = $0 }
    }
}

/// Progress bar with elapsed/total times. Click or drag the bar to seek.
private struct ProgressRow: View {
    @ObservedObject var spotify: SpotifyController
    let duration: TimeInterval
    let canSeek: Bool

    /// 0...1 while the user is dragging; the bar follows the pointer instead of playback.
    @State private var scrubFraction: CGFloat?
    @State private var isHovered = false

    var body: some View {
        // Redraw ~10×/s while playing so the bar and time advance smoothly between
        // the 1 s position polls. Paused or scrubbing, nothing needs to tick.
        TimelineView(.animation(minimumInterval: 0.1, paused: !spotify.isPlaying || scrubFraction != nil)) { context in
            let live = spotify.position(at: context.date)
            let fraction = scrubFraction ?? fraction(of: live)
            let shownTime = scrubFraction.map { Double($0) * duration } ?? live

            HStack(spacing: 8) {
                Text(Self.format(shownTime))
                    .frame(width: 34, alignment: .trailing)
                bar(fraction: fraction)
                Text(Self.format(duration))
                    .frame(width: 34, alignment: .leading)
            }
        }
        .font(.system(size: 10, weight: .medium).monospacedDigit())
        .foregroundStyle(.white.opacity(0.6))
    }

    private func bar(fraction: CGFloat) -> some View {
        let isActive = canSeek && (isHovered || scrubFraction != nil)
        let thickness: CGFloat = isActive ? 6 : 4

        return GeometryReader { proxy in
            let width = proxy.size.width
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.2))
                    .frame(height: thickness)
                Capsule().fill(Color.white)
                    .frame(width: max(thickness, width * fraction), height: thickness)
                if isActive {
                    Circle().fill(Color.white)
                        .frame(width: 11, height: 11)
                        .offset(x: width * fraction - 5.5)
                }
            }
            .frame(width: width, height: proxy.size.height)
            // The visible bar is only 4 pt tall; make the whole row height clickable.
            .contentShape(Rectangle())
            // minimumDistance 0: a plain click counts too, not just a drag.
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in scrubFraction = clamp(value.location.x / width) }
                    .onEnded { value in
                        spotify.seek(to: Double(clamp(value.location.x / width)) * duration)
                        scrubFraction = nil
                    },
                including: canSeek ? .all : .subviews
            )
        }
        .frame(height: 14)
        .onHover { isHovered = $0 }
        .animation(.easeOut(duration: 0.12), value: isActive)
    }

    private func fraction(of position: TimeInterval) -> CGFloat {
        guard duration > 0 else { return 0 }
        return clamp(CGFloat(position / duration))
    }

    private func clamp(_ value: CGFloat) -> CGFloat {
        min(max(value, 0), 1)
    }

    static func format(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded(.down))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

/// Icon + message (+ optional button) used for every "can't show the player" state.
private struct HintView: View {
    let symbol: String
    let message: String
    var actionTitle: String?
    var action: (() -> Void)?
    var compact = false

    var body: some View {
        let layout = compact
            ? AnyLayout(HStackLayout(spacing: 10))
            : AnyLayout(VStackLayout(spacing: 8))
        layout {
            Image(systemName: symbol)
                .font(.system(size: compact ? 14 : 20))
                .foregroundStyle(.white.opacity(0.6))
            Text(message)
                .font(.system(size: compact ? 11 : 13))
                .foregroundStyle(.white.opacity(0.75))
                .multilineTextAlignment(compact ? .leading : .center)
                .fixedSize(horizontal: false, vertical: true)
            if let actionTitle, let action {
                PillButton(title: actionTitle, action: action)
            }
        }
    }
}
