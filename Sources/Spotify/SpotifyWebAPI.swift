import Foundation

/// A song (or podcast episode) waiting in the Spotify queue.
struct QueueItem: Identifiable, Equatable {
    /// The same track can be queued twice, so identity includes the position.
    let id: String
    let uri: String
    let title: String
    let subtitle: String
    let imageURL: URL?
}

/// The small part of the Spotify Web API we use.
@MainActor
final class SpotifyWebAPI {
    enum APIError: LocalizedError {
        case http(status: Int, message: String?)

        var errorDescription: String? {
            switch self {
            case .http(429, _): return "Spotify is rate-limiting requests; retrying shortly"
            case .http(let status, let message): return message ?? "Spotify returned HTTP \(status)"
            }
        }
    }

    private let auth: SpotifyAuth

    init(auth: SpotifyAuth) {
        self.auth = auth
    }

    /// GET /me/player/queue: what plays after the current track.
    func fetchQueue() async throws -> [QueueItem] {
        let data = try await get(URL(string: "https://api.spotify.com/v1/me/player/queue")!)
        guard !data.isEmpty else { return [] }   // 204: no active player
        let response = try JSONDecoder().decode(QueueResponse.self, from: data)
        return response.queue.enumerated().map { index, item in
            QueueItem(
                id: "\(index)-\(item.uri)",
                uri: item.uri,
                title: item.name,
                // Tracks have artists; podcast episodes have a show instead.
                subtitle: item.artists?.map(\.name).joined(separator: ", ") ?? item.show?.name ?? "",
                // Spotify lists images largest-first; the smallest (64 px) is plenty here.
                imageURL: (item.album?.images ?? item.images ?? []).last?.url
            )
        }
    }

    private func get(_ url: URL, isRetry: Bool = false) async throws -> Data {
        var request = URLRequest(url: url)
        request.setValue("Bearer \(try await auth.accessToken())", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0

        // The token can expire early (e.g. revoked). Refresh once and retry.
        if status == 401, !isRetry {
            _ = try await auth.refreshAccessToken()
            return try await get(url, isRetry: true)
        }
        guard (200..<300).contains(status) else {
            let message = (try? JSONDecoder().decode(ErrorResponse.self, from: data))?.error.message
            throw APIError.http(status: status, message: message)
        }
        return data
    }

    // MARK: JSON shapes (only the fields we read)

    private struct QueueResponse: Decodable {
        let queue: [Item]

        struct Item: Decodable {
            let uri: String
            let name: String
            let artists: [Named]?   // tracks
            let album: Album?       // tracks
            let show: Named?        // episodes
            let images: [Image]?    // episodes
        }
        struct Named: Decodable { let name: String }
        struct Album: Decodable { let images: [Image] }
        struct Image: Decodable { let url: URL }
    }

    private struct ErrorResponse: Decodable {
        struct Body: Decodable { let message: String? }
        let error: Body
    }
}
