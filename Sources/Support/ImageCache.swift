import AppKit

/// In-memory artwork cache keyed by URL, shared by the now-playing artwork and
/// the queue rows. Concurrent requests for the same URL share one download.
@MainActor
final class ImageCache {
    static let shared = ImageCache()

    // NSCache evicts automatically under memory pressure.
    private let cache = NSCache<NSURL, NSImage>()
    private var inFlight: [URL: Task<NSImage?, Never>] = [:]

    func cachedImage(for url: URL) -> NSImage? {
        cache.object(forKey: url as NSURL)
    }

    func image(for url: URL) async -> NSImage? {
        if let cached = cachedImage(for: url) { return cached }
        if let pending = inFlight[url] { return await pending.value }

        let task = Task { () -> NSImage? in
            guard let (data, _) = try? await URLSession.shared.data(from: url) else { return nil }
            return NSImage(data: data)
        }
        inFlight[url] = task
        let image = await task.value
        inFlight[url] = nil
        if let image { cache.setObject(image, forKey: url as NSURL) }
        return image
    }
}
