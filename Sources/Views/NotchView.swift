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

extension NotchGeometry.State {
    /// The single source of truth for which state the notch is in. Used by both the
    /// view (what to draw) and the panel controller (where the hover zone is).
    @MainActor
    static func current(isExpanded: Bool, spotify: SpotifyController, queue: QueueController) -> Self {
        guard isExpanded else { return spotify.isActive ? .collapsed : .idle }
        guard spotify.track != nil else { return .expanded(.none) }
        return .expanded(queue.authState == .signedIn ? .list : .prompt)
    }
}

/// Root view: a black notch-shaped panel pinned to the top center of the window
/// that grows from idle → collapsed → expanded.
struct NotchView: View {
    @ObservedObject var model: NotchViewModel
    @ObservedObject var spotify: SpotifyController
    @ObservedObject var queue: QueueController

    private var state: NotchGeometry.State {
        .current(isExpanded: model.isExpanded, spotify: spotify, queue: queue)
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
            case .expanded(let queueLayout):
                ExpandedView(spotify: spotify, queue: queue, queueLayout: queueLayout, geometry: geometry)
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

/// Artwork loaded from a URL through the shared cache (used for queue rows).
struct RemoteArtworkView: View {
    let url: URL?
    var cornerRadius: CGFloat = 4
    @State private var image: NSImage?

    var body: some View {
        ArtworkView(image: image, cornerRadius: cornerRadius)
            // Re-runs whenever `url` changes, and is cancelled if the row goes away.
            .task(id: url) {
                guard let url else { image = nil; return }
                image = ImageCache.shared.cachedImage(for: url)
                if image == nil { image = await ImageCache.shared.image(for: url) }
            }
    }
}
