import Foundation
import Network

/// Tiny HTTP server bound to the loopback interface only (127.0.0.1), so no
/// other device can reach it. The Pebble app's watchapp JavaScript polls
/// GET /step on every tick from the watch.
public final class StepServer: @unchecked Sendable {
    public static let port: UInt16 = 8765

    private let queue = DispatchQueue(label: "StepServer")
    private let lock = NSLock()
    private var listener: NWListener?
    private var body = Data(#"{"active":false}"#.utf8)
    private var lastRequest: Date?
    private var maxGap: TimeInterval = 0
    private var requests = 0

    public init() {}

    /// Replaces what GET /step returns.
    public func publish(_ step: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: step) else { return }
        lock.lock()
        body = data
        lock.unlock()
    }

    /// When the watch last polled, the longest gap between polls, and the count.
    /// A growing gap with the phone locked means iOS suspended the Pebble app.
    public var pollStats: (last: Date?, maxGap: TimeInterval, count: Int) {
        lock.lock()
        defer { lock.unlock() }
        return (lastRequest, maxGap, requests)
    }

    public func resetStats() {
        lock.lock()
        lastRequest = nil
        maxGap = 0
        requests = 0
        lock.unlock()
    }

    public func start() throws {
        guard listener == nil else { return }
        let params = NWParameters.tcp
        params.requiredInterfaceType = .loopback
        params.allowLocalEndpointReuse = true
        let listener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: Self.port)!)
        listener.newConnectionHandler = { [weak self] connection in self?.serve(connection) }
        listener.start(queue: queue)
        self.listener = listener
    }

    public func stop() {
        listener?.cancel()
        listener = nil
    }

    private func serve(_ connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, _, _ in
            guard let self, let data, let request = String(data: data, encoding: .utf8) else {
                connection.cancel()
                return
            }
            // "GET /step?t=123 HTTP/1.1"
            let path = request.split(separator: " ").dropFirst().first.map(String.init) ?? ""
            let response: Data
            if path.hasPrefix("/step") {
                self.lock.lock()
                let now = Date()
                if let last = self.lastRequest { self.maxGap = max(self.maxGap, now.timeIntervalSince(last)) }
                self.lastRequest = now
                self.requests += 1
                let body = self.body
                self.lock.unlock()
                response = Self.http(status: "200 OK", body: body)
            } else {
                response = Self.http(status: "404 Not Found", body: Data())
            }
            connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
        }
    }

    private static func http(status: String, body: Data) -> Data {
        var head = "HTTP/1.1 \(status)\r\n"
        head += "Content-Type: application/json; charset=utf-8\r\n"
        head += "Content-Length: \(body.count)\r\n"
        head += "Cache-Control: no-store\r\nConnection: close\r\n\r\n"
        return Data(head.utf8) + body
    }
}
