import SwiftUI

/// Artwork in the left wing, equalizer in the right, and "Title — Artist".
///
/// With a notch, the middle of the top row is hidden behind the camera housing, so
/// the title goes in a strip underneath. Without one, it sits in the middle of the pill.
struct CollapsedView: View {
    @ObservedObject var spotify: SpotifyController
    let geometry: NotchGeometry

    var body: some View {
        let height = geometry.notchSize.height
        let size = geometry.shapeSize(.collapsed)

        VStack(spacing: 0) {
            HStack(spacing: 0) {
                ArtworkView(image: spotify.artwork, cornerRadius: 5)
                    .frame(width: height - 12, height: height - 12)
                if geometry.hasNotch {
                    Spacer(minLength: 0)
                } else {
                    title.padding(.horizontal, 8)
                }
                EqualizerBars(isAnimating: spotify.isPlaying)
                    .frame(width: height - 18, height: height - 20)
            }
            .padding(.horizontal, 12)
            .frame(height: height)

            if geometry.hasNotch {
                title
                    .padding(.horizontal, 16)
                    .padding(.bottom, 4)
                    .frame(height: geometry.titleStripHeight)
            }
        }
        .frame(width: size.width, height: size.height, alignment: .top)
    }

    private var title: some View {
        let track = spotify.track
        let text = [track?.name, track?.artist]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: " — ")
        return MarqueeText(text: text, isAnimating: spotify.isPlaying)
            .foregroundStyle(.white.opacity(0.85))
    }
}
