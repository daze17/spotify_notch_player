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
    @Published private(set) var isPlaying = false
    @Published private(set) var position: TimeInterval = 0
    @Published private(set) var artwork: NSImage?

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
    private let artworkCache = NSCache<NSURL, NSImage>()
    private var artworkTask: Task<Void, Never>?

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

    func launchSpotify() {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: SpotifyScript.bundleID) else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
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

        Task {
            do {
                let state = try await script.fetchState()
                status = .ready
                isPlaying = state.isPlaying
                position = state.position
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
        Task {
            do {
                position = try await script.fetchPosition()
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
        if let cached = artworkCache.object(forKey: url as NSURL) {
            artwork = cached
            return
        }
        artworkTask?.cancel()
        artworkTask = Task {
            guard let (data, _) = try? await URLSession.shared.data(from: url),
                  !Task.isCancelled,
                  let image = NSImage(data: data) else { return }
            artworkCache.setObject(image, forKey: url as NSURL)
            // The track may have changed while we were downloading.
            if track?.artworkURL == url { artwork = image }
        }
    }
}
