import Combine
import Foundation

/// Observable "Up next" state for the UI, backed by the Spotify Web API.
///
/// Spotify sends no notification when the queue changes, so it's re-fetched when
/// the track changes, when the player expands, and every 10 s while it's open.
@MainActor
final class QueueController: ObservableObject {
    enum AuthState: Equatable {
        case notConfigured   // no Client ID in the build
        case signedOut
        case signingIn       // waiting for the browser login
        case signedIn
    }

    @Published private(set) var authState: AuthState
    @Published private(set) var items: [QueueItem] = []
    @Published private(set) var errorMessage: String?

    /// Set by the UI. The queue is only polled while the expanded view is visible.
    var isVisible = false {
        didSet {
            guard isVisible != oldValue else { return }
            if isVisible { refresh() }
            updatePolling()
        }
    }

    private let spotify: SpotifyController
    private let auth = SpotifyAuth()
    private lazy var api = SpotifyWebAPI(auth: auth)
    private var signInTask: Task<Void, Never>?
    private var pendingRefresh: Task<Void, Never>?
    private var pollTimer: Timer?
    private var cancellables = Set<AnyCancellable>()

    init(spotify: SpotifyController) {
        self.spotify = spotify
        if auth.clientID == nil {
            authState = .notConfigured
        } else {
            authState = auth.isSignedIn ? .signedIn : .signedOut
        }

        // A new track means the head of the queue moved.
        spotify.$track
            .map { $0?.id }
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] _ in
                // @Published fires on the main thread here (SpotifyController is @MainActor).
                MainActor.assumeIsolated {
                    // Give the Web API a moment to catch up with the desktop client.
                    self?.refresh(after: .milliseconds(800))
                }
            }
            .store(in: &cancellables)

        refresh()
    }

    // MARK: Login

    func connect() {
        signInTask?.cancel()
        errorMessage = nil
        authState = .signingIn
        signInTask = Task {
            do {
                try await auth.signIn()
                authState = .signedIn
                refresh()
            } catch is CancellationError {
                // Replaced by a newer attempt or cancelled by the user.
            } catch LoopbackRedirectServer.ServerError.cancelled {
            } catch {
                authState = .signedOut
                errorMessage = error.localizedDescription
            }
        }
    }

    func cancelConnect() {
        signInTask?.cancel()
        signInTask = nil
        authState = .signedOut
    }

    func disconnect() {
        auth.signOut()
        items = []
        errorMessage = nil
        authState = .signedOut
    }

    // MARK: Actions

    /// Jumps to a queued item by skipping forward until it's the current track.
    /// Spotify has no "play queue item N" command, so this is the reliable way to
    /// keep the rest of the queue and the playback context intact.
    func play(_ item: QueueItem) {
        guard let index = items.firstIndex(of: item) else { return }
        spotify.skipForward(count: index + 1)
    }

    // MARK: Fetching

    func refresh(after delay: Duration = .zero) {
        guard authState == .signedIn else { return }
        pendingRefresh?.cancel()
        pendingRefresh = Task {
            if delay > .zero {
                try? await Task.sleep(for: delay)
                if Task.isCancelled { return }
            }
            do {
                let queue = try await api.fetchQueue()
                items = queue
                errorMessage = nil
            } catch SpotifyAuth.AuthError.signedOut {
                items = []
                authState = .signedOut
            } catch is CancellationError {
            } catch let error as URLError where error.code == .cancelled {
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func updatePolling() {
        if isVisible, pollTimer == nil {
            let timer = Timer(timeInterval: 10, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            }
            RunLoop.main.add(timer, forMode: .common)
            pollTimer = timer
        } else if !isVisible {
            pollTimer?.invalidate()
            pollTimer = nil
        }
    }
}
