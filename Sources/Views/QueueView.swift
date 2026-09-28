import SwiftUI

/// The bottom section of the expanded player: "Up next", or a prompt to connect.
struct QueueView: View {
    @ObservedObject var queue: QueueController
    let layout: NotchGeometry.QueueLayout
    let geometry: NotchGeometry

    var body: some View {
        Group {
            switch layout {
            case .none:
                EmptyView()
            case .prompt:
                prompt
            case .list:
                list
            }
        }
        .frame(height: geometry.queueHeight(layout), alignment: .top)
    }

    // MARK: Prompt

    @ViewBuilder
    private var prompt: some View {
        HStack(spacing: 10) {
            Image(systemName: "list.bullet")
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.5))
            switch queue.authState {
            case .notConfigured:
                promptText("Add a Spotify Client ID to see Up Next (see README)")
            case .signingIn:
                promptText("Finish logging in in your browser…")
                PillButton(title: "Cancel", action: queue.cancelConnect)
            case .signedOut, .signedIn:
                promptText(queue.errorMessage ?? "Connect Spotify to see what's up next")
                PillButton(title: "Connect", action: queue.connect)
            }
        }
        .padding(.horizontal, 22)
        .frame(maxHeight: .infinity)
        .overlay(alignment: .top) { divider }
    }

    private func promptText(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(.white.opacity(0.7))
            .lineLimit(2)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: List

    private var list: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("UP NEXT")
                .font(.system(size: 10, weight: .semibold))
                .tracking(0.8)
                .foregroundStyle(.white.opacity(0.45))
                .padding(.horizontal, 22)
                .frame(height: 26)
                // Right-click the header to sign out of the Web API.
                .contextMenu {
                    Button("Disconnect Spotify Account", action: queue.disconnect)
                }

            if queue.items.isEmpty {
                Text(queue.errorMessage ?? "Nothing queued")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.5))
                    .lineLimit(2)
                    .padding(.horizontal, 22)
                    .padding(.top, 6)
            } else {
                let scrolls = queue.items.count > NotchGeometry.queueRows
                ScrollView(.vertical) {
                    // Lazy: rows (and their artwork downloads) are only created as
                    // they scroll into view.
                    LazyVStack(spacing: 0) {
                        ForEach(queue.items) { item in
                            QueueRow(item: item) { queue.play(item) }
                        }
                    }
                    // Room at the end so the last row can scroll clear of the fade.
                    .padding(.bottom, scrolls ? 14 : 0)
                }
                .scrollIndicators(.automatic)
                // Don't rubber-band when everything already fits.
                .scrollBounceBehavior(.basedOnSize)
                .mask { scrolls ? AnyView(bottomFade) : AnyView(Color.black) }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .overlay(alignment: .top) { divider }
    }

    /// Fades out the bottom edge to hint that the list continues.
    private var bottomFade: some View {
        LinearGradient(stops: [
            .init(color: .black, location: 0),
            .init(color: .black, location: 0.82),
            .init(color: .clear, location: 1),
        ], startPoint: .top, endPoint: .bottom)
    }

    private var divider: some View {
        Rectangle()
            .fill(Color.white.opacity(0.08))
            .frame(height: 1)
            .padding(.horizontal, 16)
    }
}

private struct QueueRow: View {
    let item: QueueItem
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                RemoteArtworkView(url: item.imageURL, cornerRadius: 4)
                    .frame(width: 26, height: 26)
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.title)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.white.opacity(0.9))
                    Text(item.subtitle)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.white.opacity(0.5))
                }
                .lineLimit(1)
                Spacer(minLength: 0)
                Image(systemName: "play.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(isHovered ? 0.8 : 0))
            }
            .padding(.horizontal, 10)
            .frame(height: NotchGeometry.queueRowHeight)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.white.opacity(isHovered ? 0.08 : 0))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 12)
        .onHover { isHovered = $0 }
        .help("Skip to this song")
    }
}

/// Small capsule button used in hints and prompts.
struct PillButton: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(title, action: action)
            .buttonStyle(.plain)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(Capsule().fill(Color.white.opacity(0.15)))
            .contentShape(Capsule())
    }
}
