import Foundation
import Network

/// A one-shot HTTP server on 127.0.0.1 that catches the OAuth redirect.
///
/// After login, Spotify redirects the browser to `http://127.0.0.1:43117/callback?code=…`.
/// This listens there, answers with a "you can close this tab" page and hands the
/// URL back. It only binds to the loopback interface, so nothing outside this Mac
/// can connect (and the macOS firewall doesn't prompt).
final class LoopbackRedirectServer: @unchecked Sendable {
    static let port: UInt16 = 43117
    static let redirectURI = "http://127.0.0.1:\(port)/callback"

    enum ServerError: Error {
        case couldNotStart(Error)
        case timedOut
        case cancelled
    }

    private let queue = DispatchQueue(label: "com.bilguun.NotchPlayer.LoopbackRedirectServer")
    // Only touched on `queue`.
    private var listener: NWListener?
    private var continuation: CheckedContinuation<URL, Error>?

    /// Starts listening and waits for the browser to hit /callback.
    func waitForCallback(timeout: Duration = .seconds(300)) async throws -> URL {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                queue.async { self.start(continuation, timeout: timeout) }
            }
        } onCancel: {
            queue.async { self.finish(.failure(ServerError.cancelled)) }
        }
    }

    private func start(_ continuation: CheckedContinuation<URL, Error>, timeout: Duration) {
        self.continuation = continuation
        do {
            let parameters = NWParameters.tcp
            parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: Self.port)!)
            parameters.allowLocalEndpointReuse = true
            let listener = try NWListener(using: parameters)
            listener.newConnectionHandler = { [weak self] connection in self?.handle(connection) }
            listener.stateUpdateHandler = { [weak self] state in
                if case .failed(let error) = state { self?.finish(.failure(ServerError.couldNotStart(error))) }
            }
            listener.start(queue: queue)
            self.listener = listener
        } catch {
            finish(.failure(ServerError.couldNotStart(error)))
            return
        }
        let seconds = Double(timeout.components.seconds)
        queue.asyncAfter(deadline: .now() + seconds) { [weak self] in
            self?.finish(.failure(ServerError.timedOut))
        }
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, _, _ in
            guard let self else { return }
            // We only need the request line: "GET /callback?code=…&state=… HTTP/1.1"
            let request = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            let path = request.split(separator: " ", maxSplits: 2).dropFirst().first.map(String.init) ?? ""

            guard path.hasPrefix("/callback"), let url = URL(string: "http://127.0.0.1:\(Self.port)\(path)") else {
                // e.g. the browser asking for /favicon.ico
                self.respond(on: connection, status: "404 Not Found", body: "Not found")
                return
            }
            let failed = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.contains { $0.name == "error" } ?? false
            self.respond(on: connection, status: "200 OK", body: failed
                ? "Spotify login was cancelled. You can close this tab."
                : "NotchPlayer is connected to Spotify. You can close this tab.")
            self.finish(.success(url))
        }
    }

    private func respond(on connection: NWConnection, status: String, body: String) {
        let html = """
        <!doctype html><meta charset="utf-8"><title>NotchPlayer</title>
        <body style="font:16px -apple-system,sans-serif;display:grid;place-items:center;height:90vh">\(body)</body>
        """
        let response = "HTTP/1.1 \(status)\r\nContent-Type: text/html; charset=utf-8\r\n"
            + "Content-Length: \(html.utf8.count)\r\nConnection: close\r\n\r\n\(html)"
        connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
    }

    /// Resumes the waiting caller exactly once and shuts the listener down.
    private func finish(_ result: Result<URL, Error>) {
        guard let continuation else { return }
        self.continuation = nil
        listener?.cancel()
        listener = nil
        continuation.resume(with: result)
    }
}
