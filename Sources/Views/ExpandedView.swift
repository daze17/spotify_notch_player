import SwiftUI

/// The hovered state: artwork, title/artist, progress and transport controls,
/// or a hint when Spotify isn't available.
struct ExpandedView: View {
    @ObservedObject var spotify: SpotifyController
    let geometry: NotchGeometry

    var body: some View {
        let size = geometry.shapeSize(.expanded)

        VStack(spacing: 0) {
            // Space hidden behind the physical camera housing.
            Color.clear.frame(height: geometry.contentTopInset)
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.horizontal, 22)
                .padding(.top, 10)
                .padding(.bottom, 16)
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
                     actionTitle: "Open Spotify", action: spotify.launchSpotify)
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
            }

            ProgressRow(position: spotify.position, duration: track.duration, isPlaying: spotify.isPlaying)

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

/// Display-only progress bar with elapsed/total times.
private struct ProgressRow: View {
    let position: TimeInterval
    let duration: TimeInterval
    let isPlaying: Bool

    private var fraction: CGFloat {
        guard duration > 0 else { return 0 }
        return CGFloat(min(max(position / duration, 0), 1))
    }

    var body: some View {
        HStack(spacing: 8) {
            Text(Self.format(position))
                .frame(width: 34, alignment: .trailing)
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.2))
                    Capsule().fill(Color.white)
                        .frame(width: proxy.size.width * fraction)
                        // Position arrives once a second; glide between samples
                        // while playing instead of jumping.
                        .animation(isPlaying ? .linear(duration: 1) : .default, value: fraction)
                }
            }
            .frame(height: 4)
            Text(Self.format(duration))
                .frame(width: 34, alignment: .leading)
        }
        .font(.system(size: 10, weight: .medium).monospacedDigit())
        .foregroundStyle(.white.opacity(0.6))
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
                Button(actionTitle, action: action)
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .semibold))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(Color.white.opacity(0.15)))
                    .contentShape(Capsule())
            }
        }
    }
}
