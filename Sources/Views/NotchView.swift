import SwiftUI

/// UI state shared between the AppKit panel controller and the SwiftUI views.
@MainActor
final class NotchViewModel: ObservableObject {
    @Published var geometry: NotchGeometry
    @Published var isExpanded = false

    init(geometry: NotchGeometry) {
        self.geometry = geometry
    }
}

/// Root view: a black notch-shaped panel pinned to the top center of the window
/// that grows from idle → collapsed → expanded.
struct NotchView: View {
    @ObservedObject var model: NotchViewModel
    @ObservedObject var spotify: SpotifyController

    private var state: NotchGeometry.State {
        if model.isExpanded { return .expanded }
        return spotify.isActive ? .collapsed : .idle
    }

    var body: some View {
        let geometry = model.geometry
        let size = geometry.shapeSize(state)
        let radii = geometry.cornerRadii(state)
        let shape = UnevenRoundedRectangle(
            topLeadingRadius: radii.top,
            bottomLeadingRadius: radii.bottom,
            bottomTrailingRadius: radii.bottom,
            topTrailingRadius: radii.top,
            style: .continuous
        )

        ZStack(alignment: .top) {
            shape.fill(Color.black)

            switch state {
            case .expanded:
                ExpandedView(spotify: spotify, geometry: geometry)
                    .transition(.opacity.animation(.easeOut(duration: 0.15)))
            case .collapsed:
                CollapsedView(spotify: spotify, geometry: geometry)
                    .transition(.opacity.animation(.easeOut(duration: 0.15)))
            case .idle:
                EmptyView()
            }
        }
        .frame(width: size.width, height: size.height, alignment: .top)
        // Content is laid out at its final size; clip it to the shape while the
        // shape is still growing.
        .clipShape(shape)
        // Pin to the top center of the (larger) panel.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(.spring(response: 0.38, dampingFraction: 0.78), value: state)
    }
}

/// Album art with a placeholder while it loads (or for local files, which have none).
struct ArtworkView: View {
    let image: NSImage?
    var cornerRadius: CGFloat = 6

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                shape
                    .fill(Color.white.opacity(0.12))
                    .overlay(
                        Image(systemName: "music.note")
                            .resizable()
                            .scaledToFit()
                            .padding(6)
                            .foregroundStyle(.white.opacity(0.5))
                    )
            }
        }
        .clipShape(shape)
    }
}
