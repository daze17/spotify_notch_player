import AppKit
import CryptoKit

/// Spotify Web API login using the Authorization Code flow with PKCE.
///
/// PKCE is the OAuth variant for apps that can't keep a client secret: we make
/// a random `verifier`, send its SHA-256 hash with the login request, and later
/// prove we started the login by sending the original verifier when trading the
/// code for tokens. Only the (public) client ID is embedded in the app.
@MainActor
final class SpotifyAuth {
    enum AuthError: LocalizedError {
        case notConfigured
        case signedOut
        case denied(String)
        case stateMismatch
        case tokenRequestFailed(String)

        var errorDescription: String? {
            switch self {
            case .notConfigured: return "No Spotify Client ID configured"
            case .signedOut: return "Not connected to Spotify"
            case .denied(let reason): return "Spotify login failed: \(reason)"
            case .stateMismatch: return "Spotify login response didn't match the request"
            case .tokenRequestFailed(let reason): return "Spotify token request failed: \(reason)"
            }
        }
    }

    private struct Tokens: Codable {
        var accessToken: String
        var refreshToken: String
        var expiresAt: Date
    }

    // user-read-playback-state covers GET /me/player/queue.
    private static let scopes = "user-read-playback-state user-read-currently-playing"
    private static let keychainAccount = "spotify-tokens"

    /// Read from Info.plist, which gets it from the SPOTIFY_CLIENT_ID build setting.
    let clientID: String?
    private var tokens: Tokens? {
        didSet {
            if let tokens, let data = try? JSONEncoder().encode(tokens) {
                Keychain.write(data, for: Self.keychainAccount)
            } else {
                Keychain.delete(Self.keychainAccount)
            }
        }
    }
    private var refreshTask: Task<String, Error>?

    init() {
        let id = (Bundle.main.object(forInfoDictionaryKey: "SpotifyClientID") as? String)?
            .trimmingCharacters(in: .whitespaces)
        clientID = (id?.isEmpty == false) ? id : nil
        tokens = Keychain.read(Self.keychainAccount).flatMap { try? JSONDecoder().decode(Tokens.self, from: $0) }
    }

    var isSignedIn: Bool { tokens != nil }

    // MARK: Login

    /// Opens Spotify's login page in the default browser and waits for the redirect.
    func signIn() async throws {
        guard let clientID else { throw AuthError.notConfigured }

        let verifier = Self.randomString(length: 64)
        let state = Self.randomString(length: 16)
        var components = URLComponents(string: "https://accounts.spotify.com/authorize")!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri", value: LoopbackRedirectServer.redirectURI),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "code_challenge", value: Self.codeChallenge(for: verifier)),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "scope", value: Self.scopes),
        ]

        // Start listening *before* opening the browser so the redirect can't race us.
        let server = LoopbackRedirectServer()
        async let callback = server.waitForCallback()
        NSWorkspace.shared.open(components.url!)
        let callbackURL = try await callback

        let query = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ name: String) -> String? { query.first { $0.name == name }?.value }

        // `state` guards against another page on this Mac feeding us its own code.
        guard value("state") == state else { throw AuthError.stateMismatch }
        if let error = value("error") { throw AuthError.denied(error) }
        guard let code = value("code") else { throw AuthError.denied("no code returned") }

        tokens = try await requestTokens([
            "grant_type": "authorization_code",
            "code": code,
            "redirect_uri": LoopbackRedirectServer.redirectURI,
            "client_id": clientID,
            "code_verifier": verifier,
        ], previousRefreshToken: nil)
    }

    func signOut() {
        refreshTask?.cancel()
        refreshTask = nil
        tokens = nil
    }

    // MARK: Tokens

    /// A valid access token, refreshed first if it expires within a minute.
    func accessToken() async throws -> String {
        guard let tokens else { throw AuthError.signedOut }
        if tokens.expiresAt > Date().addingTimeInterval(60) { return tokens.accessToken }
        return try await refreshAccessToken()
    }

    /// Trades the refresh token for a new access token. Concurrent callers share
    /// one request, since Spotify may rotate the refresh token on each use.
    func refreshAccessToken() async throws -> String {
        if let refreshTask { return try await refreshTask.value }
        guard let clientID, let refreshToken = tokens?.refreshToken else { throw AuthError.signedOut }

        let task = Task { () throws -> String in
            defer { refreshTask = nil }
            do {
                let fresh = try await requestTokens([
                    "grant_type": "refresh_token",
                    "refresh_token": refreshToken,
                    "client_id": clientID,
                ], previousRefreshToken: refreshToken)
                tokens = fresh
                return fresh.accessToken
            } catch AuthError.denied {
                // The refresh token was revoked (e.g. the app was removed in the
                // Spotify account page). Forget it so the UI asks to reconnect.
                tokens = nil
                throw AuthError.signedOut
            }
        }
        refreshTask = task
        return try await task.value
    }

    private func requestTokens(_ form: [String: String], previousRefreshToken: String?) async throws -> Tokens {
        struct Response: Decodable {
            let access_token: String
            let expires_in: Double
            let refresh_token: String?
        }
        struct ErrorResponse: Decodable {
            let error: String
            let error_description: String?
        }

        var request = URLRequest(url: URL(string: "https://accounts.spotify.com/api/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(Self.formEncode(form).utf8)

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            let error = try? JSONDecoder().decode(ErrorResponse.self, from: data)
            if error?.error == "invalid_grant" { throw AuthError.denied(error?.error_description ?? "invalid_grant") }
            throw AuthError.tokenRequestFailed(error?.error_description ?? error?.error ?? "HTTP \(status)")
        }
        let body = try JSONDecoder().decode(Response.self, from: data)
        guard let refreshToken = body.refresh_token ?? previousRefreshToken else {
            throw AuthError.tokenRequestFailed("no refresh token returned")
        }
        return Tokens(accessToken: body.access_token,
                      refreshToken: refreshToken,
                      expiresAt: Date().addingTimeInterval(body.expires_in))
    }

    // MARK: Helpers

    private static func randomString(length: Int) -> String {
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789")
        var generator = SystemRandomNumberGenerator()   // cryptographically secure on Apple platforms
        return String((0..<length).map { _ in alphabet.randomElement(using: &generator)! })
    }

    /// base64url(SHA-256(verifier)), without padding, as PKCE requires.
    private static func codeChallenge(for verifier: String) -> String {
        Data(SHA256.hash(data: Data(verifier.utf8))).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func formEncode(_ form: [String: String]) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return form.map { key, value in
            "\(key)=\(value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value)"
        }.joined(separator: "&")
    }
}
