import AppKit

/// Talks to Spotify over AppleScript (Apple events).
///
/// Every script runs on one private serial queue. NSAppleScript isn't safe to use
/// concurrently, and a single Apple event can block for a long time (for example
/// while macOS shows the Automation permission prompt, or if Spotify hangs). Doing
/// that on the main thread would freeze the UI.
///
/// `@unchecked Sendable`: the only mutable state (`compiled`) is touched solely
/// on `queue`, which the compiler can't verify for us.
final class SpotifyScript: @unchecked Sendable {
    static let bundleID = "com.spotify.client"

    enum ScriptError: Error {
        /// The user denied (or later revoked) the Automation permission.
        case permissionDenied
        case notRunning
        case failed(code: Int, message: String)
    }

    struct TrackInfo: Equatable {
        var id: String
        var name: String
        var artist: String
        var album: String
        var duration: TimeInterval   // seconds
        var artworkURL: URL?
    }

    struct PlayerState {
        var isPlaying: Bool
        var position: TimeInterval   // seconds
        var track: TrackInfo?        // nil when Spotify is open with nothing loaded
    }

    enum Command: String {
        case playPause = "playpause"
        case next = "next track"
        case previous = "previous track"
    }

    // MARK: Availability (no Apple events involved)

    static var isInstalled: Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) != nil
    }

    static var isRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
    }

    // MARK: Scripts
    //
    // Two things matter in every script:
    // - `application id "…" is running` checks without launching. A bare
    //   `tell application "Spotify"` would *launch* Spotify if it had just quit.
    // - Callers must check `isInstalled` first. Compiling a script that names a
    //   missing app makes AppleScript pop up a "Where is Spotify?" dialog.

    private static let stateSource = """
    if application id "com.spotify.client" is running then
        tell application id "com.spotify.client"
            set stateText to player state as string
            try
                set theTrack to current track
                return {stateText, player position, duration of theTrack, artwork url of theTrack, id of theTrack, name of theTrack, artist of theTrack, album of theTrack}
            on error
                return {stateText, 0}
            end try
        end tell
    end if
    return {"not running"}
    """

    private static let positionSource = """
    if application id "com.spotify.client" is running then
        tell application id "com.spotify.client" to return player position
    end if
    return -1
    """

    private static func commandSource(_ command: Command) -> String {
        """
        if application id "com.spotify.client" is running then
            tell application id "com.spotify.client" to \(command.rawValue)
        end if
        """
    }

    /// `next track` repeated, with a short pause so Spotify doesn't drop any.
    private static func skipSource(count: Int) -> String {
        """
        if application id "com.spotify.client" is running then
            tell application id "com.spotify.client"
                repeat \(count) times
                    next track
                    delay 0.15
                end repeat
            end tell
        end if
        """
    }

    // MARK: Public API

    func fetchState() async throws -> PlayerState {
        let result = try await run(Self.stateSource)
        guard let state = result.atIndex(1)?.stringValue, state != "not running" else {
            throw ScriptError.notRunning
        }
        var player = PlayerState(isPlaying: state == "playing",
                                 position: result.atIndex(2)?.doubleValue ?? 0,
                                 track: nil)
        // AppleScript lists are 1-indexed.
        if result.numberOfItems >= 8, let id = result.atIndex(5)?.stringValue, !id.isEmpty {
            player.track = TrackInfo(
                id: id,
                name: result.atIndex(6)?.stringValue ?? "",
                artist: result.atIndex(7)?.stringValue ?? "",
                album: result.atIndex(8)?.stringValue ?? "",
                duration: (result.atIndex(3)?.doubleValue ?? 0) / 1000,   // Spotify reports ms
                // `missing value` for local files → stringValue is nil.
                artworkURL: result.atIndex(4)?.stringValue.flatMap(URL.init(string:))
            )
        }
        return player
    }

    func fetchPosition() async throws -> TimeInterval {
        let position = try await run(Self.positionSource).doubleValue
        if position < 0 { throw ScriptError.notRunning }
        return position
    }

    func send(_ command: Command) async throws {
        _ = try await run(Self.commandSource(command))
    }

    func skip(count: Int) async throws {
        _ = try await run(Self.skipSource(count: count))
    }

    func seek(to seconds: TimeInterval) async throws {
        // String(format:) always uses "." as the decimal separator, which is what
        // AppleScript expects regardless of the user's locale.
        let source = """
        if application id "com.spotify.client" is running then
            tell application id "com.spotify.client" to set player position to \(String(format: "%.2f", max(0, seconds)))
        end if
        """
        // Every seek has a different source, so don't keep the compiled script.
        _ = try await run(source, cache: false)
    }

    // MARK: Execution

    private let queue = DispatchQueue(label: "com.bilguun.NotchPlayer.SpotifyScript")
    /// Compiled scripts, keyed by source. Only touched on `queue`.
    private var compiled: [String: NSAppleScript] = [:]

    private func run(_ source: String, cache: Bool = true) async throws -> NSAppleEventDescriptor {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                let script: NSAppleScript
                if let cached = compiled[source] {
                    script = cached
                } else if let fresh = NSAppleScript(source: source) {
                    if cache { compiled[source] = fresh }
                    script = fresh
                } else {
                    continuation.resume(throwing: ScriptError.failed(code: 0, message: "Invalid script"))
                    return
                }

                var errorInfo: NSDictionary?
                let result = script.executeAndReturnError(&errorInfo)
                if let errorInfo {
                    let code = errorInfo[NSAppleScript.errorNumber] as? Int ?? 0
                    let message = errorInfo[NSAppleScript.errorMessage] as? String ?? "Unknown error"
                    switch code {
                    case -1743: // errAEEventNotPermitted: Automation permission denied
                        continuation.resume(throwing: ScriptError.permissionDenied)
                    case -600:  // procNotFound: Spotify quit mid-script
                        continuation.resume(throwing: ScriptError.notRunning)
                    default:
                        continuation.resume(throwing: ScriptError.failed(code: code, message: message))
                    }
                } else {
                    continuation.resume(returning: result)
                }
            }
        }
    }
}
