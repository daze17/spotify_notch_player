import AppKit
import os

typealias SpotifyTrack = SpotifyScript.TrackInfo

/// Observable Spotify state for the UI, plus playback commands.
///
/// Track and play/pause changes are pushed by Spotify through a distributed
/// notification, so they aren't polled. AppleScript fills in what the notification
/// lacks (artwork URL, live position) and sends the commands.
@MainActor
final class SpotifyController: NSObject, ObservableObject {
    enum Status: Equatable {
        case notInstalled
        case notRunning
        case permissionDenied
        case ready
    }

    @Published private(set) var status: Status = .notRunning
    @Published private(set) var track: SpotifyTrack?
    @Published private(set) var isPlaying = false {
        didSet {
            guard isPlaying != oldValue else { return }
            if oldValue {
                // Pausing: freeze the position where the local clock got to.
                position += Date().timeIntervalSince(positionSampledAt)
            } else {
                // Resuming: start counting from now, not from before the pause.
                positionSampledAt = Date()
            }
        }
    }
    /// Last known position in seconds. Use `position(at:)` for a live value.
    @Published private(set) var position: TimeInterval = 0 {
        didSet { positionSampledAt = Date() }
    }
    /// When `position` was last set, so the UI can extrapolate between samples.
    private var positionSampledAt = Date()
    /// Bumped on every seek. Position reads started before a seek are discarded,
    /// otherwise a slow poll could snap the bar back to the old spot.
    private var seekGeneration = 0
    @Published private(set) var artwork: NSImage?

    /// The playback position right now, extrapolated from the last sample while
    /// playing. Lets the progress bar move smoothly between 1 s polls.
    func position(at date: Date) -> TimeInterval {
        guard isPlaying else { return position }
        let live = position + date.timeIntervalSince(positionSampledAt)
        return min(live, track?.duration ?? live)
    }

    /// Something is playing right now, so the collapsed indicators should show.
    var isActive: Bool { track != nil && isPlaying }

    /// Set by the UI. Position is only polled while the expanded view is visible.
    var isExpandedVisible = false {
        didSet {
            guard isExpandedVisible != oldValue else { return }
            if isExpandedVisible { pollPosition() }
            updatePolling()
        }
    }

    private let script = SpotifyScript()
    private let logger = Logger(subsystem: "com.bilguun.NotchPlayer", category: "Spotify")
    private var positionTimer: Timer?

    override init() {
        super.init()

        // Spotify broadcasts this on every track change and play/pause.
        // .deliverImmediately matters: AppKit suspends distributed notifications
        // while an app is inactive, and an accessory app is almost never active.
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(playbackStateChanged(_:)),
            name: Notification.Name("com.spotify.client.PlaybackStateChanged"),
            object: nil,
            suspensionBehavior: .deliverImmediately
        )

        let workspace = NSWorkspace.shared.notificationCenter
        workspace.addObserver(self, selector: #selector(applicationLaunched(_:)),
                              name: NSWorkspace.didLaunchApplicationNotification, object: nil)
        workspace.addObserver(self, selector: #selector(applicationTerminated(_:)),
                              name: NSWorkspace.didTerminateApplicationNotification, object: nil)

        refresh()
    }

    // MARK: Commands

    func playPause() { send(.playPause) }
    func nextTrack() { send(.next) }
    func previousTrack() { send(.previous) }

    /// Jumps to `seconds` into the current track.
    func seek(to seconds: TimeInterval) {
        seekGeneration += 1
        position = seconds   // optimistic: move the bar now, not after the round-trip
        Task {
            do {
                try await script.seek(to: seconds)
            } catch {
                handle(error)
            }
        }
    }

    /// Skips `count` tracks forward (used to jump to an item in the queue).
    func skipForward(count: Int) {
        guard count > 0 else { return }
        Task {
            do {
                try await script.skip(count: count)
            } catch {
                handle(error)
            }
        }
    }

    /// Launches Spotify, or brings its window to the front if it's already running.
    ///
    /// `NSRunningApplication.activate()` would be the obvious call, but since macOS 14
    /// an app can only hand focus to another app while it's active itself, and ours
    /// never is. Asking Launch Services to "open" the app always works.
    func openSpotify() {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: SpotifyScript.bundleID) else { return }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: configuration)
    }

    func openAutomationSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation") {
            NSWorkspace.shared.open(url)
        }
    }

    private func send(_ command: SpotifyScript.Command) {
        Task {
            do {
                try await script.send(command)
            } catch {
                handle(error)
            }
        }
    }

    // MARK: State

    /// Re-read the full player state over AppleScript.
    func refresh() {
        guard SpotifyScript.isInstalled else { return reset(to: .notInstalled) }
        guard SpotifyScript.isRunning else { return reset(to: .notRunning) }

        let generation = seekGeneration
        Task {
            do {
                let state = try await script.fetchState()
                status = .ready
                isPlaying = state.isPlaying
                if generation == seekGeneration { position = state.position }
                setTrack(state.track)
                loadArtwork(state.track?.artworkURL)
                updatePolling()
            } catch {
                handle(error)
            }
        }
    }

    private func setTrack(_ newTrack: SpotifyTrack?) {
        guard newTrack != track else { return }
        if newTrack?.id != track?.id {
            artwork = nil
            if let newTrack {
                logger.notice("Now playing: \(newTrack.name, privacy: .public) — \(newTrack.artist, privacy: .public)")
            } else {
                logger.notice("No track")
            }
        }
        track = newTrack
    }

    private func reset(to status: Status) {
        self.status = status
        setTrack(nil)
        isPlaying = false
        position = 0
        updatePolling()
    }

    private func handle(_ error: Error) {
        switch error {
        case SpotifyScript.ScriptError.permissionDenied:
            // Keep whatever the notification told us (name/artist/state still show);
            // the view adds a hint about granting access.
            status = .permissionDenied
            updatePolling()
        case SpotifyScript.ScriptError.notRunning:
            reset(to: .notRunning)
        default:
            logger.error("AppleScript failed: \(String(describing: error), privacy: .public)")
        }
    }

    // MARK: Notifications

    @objc private func playbackStateChanged(_ notification: Notification) {
        let info = notification.userInfo ?? [:]
        let playerState = info["Player State"] as? String   // "Playing" | "Paused" | "Stopped"
        logger.debug("PlaybackStateChanged: \(playerState ?? "?", privacy: .public)")

        if playerState == "Stopped" {
            setTrack(nil)
            isPlaying = false
            updatePolling()
            return
        }

        // Apply the payload right away. It works even without Automation permission
        // and makes the UI react instantly.
        if let id = info["Track ID"] as? String {
            let sameTrack = id == track?.id
            setTrack(SpotifyTrack(
                id: id,
                name: info["Name"] as? String ?? "",
                artist: info["Artist"] as? String ?? "",
                album: info["Album"] as? String ?? "",
                duration: ((info["Duration"] as? NSNumber)?.doubleValue ?? 0) / 1000,
                artworkURL: sameTrack ? track?.artworkURL : nil
            ))
        }
        isPlaying = playerState == "Playing"
        if let seconds = (info["Playback Position"] as? NSNumber)?.doubleValue {
            position = seconds
        }
        updatePolling()

        // Then fetch what the notification doesn't carry (artwork URL).
        refresh()
    }

    @objc private func applicationLaunched(_ notification: Notification) {
        guard isSpotify(notification) else { return }
        refresh()
    }

    @objc private func applicationTerminated(_ notification: Notification) {
        guard isSpotify(notification) else { return }
        reset(to: SpotifyScript.isInstalled ? .notRunning : .notInstalled)
    }

    private func isSpotify(_ notification: Notification) -> Bool {
        let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
        return app?.bundleIdentifier == SpotifyScript.bundleID
    }

    // MARK: Position polling

    private func updatePolling() {
        let shouldPoll = isExpandedVisible && isPlaying && status == .ready
        if shouldPoll, positionTimer == nil {
            let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
                // Timers added to the main run loop fire on the main thread.
                MainActor.assumeIsolated { self?.pollPosition() }
            }
            timer.tolerance = 0.1
            // .common mode keeps the timer firing while a menu or scroll is tracking.
            RunLoop.main.add(timer, forMode: .common)
            positionTimer = timer
        } else if !shouldPoll {
            positionTimer?.invalidate()
            positionTimer = nil
        }
    }

    private func pollPosition() {
        guard status == .ready else { return }
        let generation = seekGeneration
        Task {
            do {
                let seconds = try await script.fetchPosition()
                if generation == seekGeneration { position = seconds }
            } catch {
                handle(error)
            }
        }
    }

    // MARK: Artwork

    private func loadArtwork(_ url: URL?) {
        guard let url else {
            artwork = nil
            return
        }
        if let cached = ImageCache.shared.cachedImage(for: url) {
            artwork = cached
            return
        }
        Task {
            let image = await ImageCache.shared.image(for: url)
            // The track may have changed while we were downloading.
            if track?.artworkURL == url { artwork = image }
        }
    }
}
