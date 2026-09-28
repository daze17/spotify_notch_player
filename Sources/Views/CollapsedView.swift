import SwiftUI

/// The minimized island. It stays within the menu bar's height.
///
/// With a notch the middle is hidden behind the camera housing, so the text is
/// split around it: artwork + title in the left wing, artist + equalizer in the
/// right. Without a notch, "Title — Artist" sits in the middle of the pill.
struct CollapsedView: View {
    @ObservedObject var spotify: SpotifyController
    let geometry: NotchGeometry

    var body: some View {
        let height = geometry.notchSize.height
        let size = geometry.shapeSize(.collapsed)

        HStack(spacing: 0) {
            ArtworkView(image: spotify.artwork, cornerRadius: 5)
                .frame(width: height - 12, height: height - 12)

            if geometry.hasNotch {
                MarqueeText(text: spotify.track?.name ?? "", font: .system(size: 11.5, weight: .semibold),
                            isAnimating: spotify.isPlaying)
                    .foregroundStyle(.white.opacity(0.9))
                    .padding(.leading, 8)
                    .padding(.trailing, 10)
                // The notch itself: keep this empty.
                Color.clear.frame(width: geometry.notchSize.width)
                MarqueeText(text: spotify.track?.artist ?? "", font: .system(size: 11, weight: .medium),
                            isAnimating: spotify.isPlaying)
                    .foregroundStyle(.white.opacity(0.6))
                    .padding(.leading, 10)
                    .padding(.trailing, 8)
            } else {
                MarqueeText(text: titleAndArtist, isAnimating: spotify.isPlaying)
                    .foregroundStyle(.white.opacity(0.85))
                    .padding(.horizontal, 8)
            }

            EqualizerBars(isAnimating: spotify.isPlaying)
                .frame(width: height - 18, height: height - 20)
        }
        .padding(.horizontal, 12)
        .frame(width: size.width, height: size.height)
    }

    private var titleAndArtist: String {
        [spotify.track?.name, spotify.track?.artist]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: " — ")
    }
}
