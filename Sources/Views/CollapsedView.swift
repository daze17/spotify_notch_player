import SwiftUI

/// Artwork in the left wing, equalizer in the right; the middle stays empty behind
/// the physical notch.
struct CollapsedView: View {
    @ObservedObject var spotify: SpotifyController
    let geometry: NotchGeometry

    var body: some View {
        let height = geometry.notchSize.height
        let size = geometry.shapeSize(.collapsed)

        HStack(spacing: 0) {
            ArtworkView(image: spotify.artwork, cornerRadius: 5)
                .frame(width: height - 12, height: height - 12)
            Spacer(minLength: 0)
            EqualizerBars(isAnimating: spotify.isPlaying)
                .frame(width: height - 18, height: height - 20)
        }
        .padding(.horizontal, 12)
        .frame(width: size.width, height: size.height)
    }
}
