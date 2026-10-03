import Foundation
import Network

/// Tiny HTTP server bound to the loopback interface only (127.0.0.1), so no
/// other device can reach it. The Pebble app's watchapp JavaScript polls
/// GET /step on every tick from the watch.
public final class StepServer: @unchecked Sendable {
    public static let port: UInt16 = 8765

    public enum State: Equatable, Sendable {
        case starting, running
        case failed(String)
    }

    /// Called on the server's queue whenever the listener's state changes.
    public var onStateChange: (@Sendable (State) -> Void)?
    /// Called on the server's queue for every GET /step, with the time since the
    /// previous one (nil for the first).
    public var onPoll: (@Sendable (_ time: Date, _ gap: TimeInterval?) -> Void)?

    /// A longer gap between polls means the watchapp was closed in between, so the
    /// next poll starts a new session.
    public static let sessionGap: TimeInterval = 30

    private let queue = DispatchQueue(label: "StepServer")
    private let lock = NSLock()
    private var listener: NWListener?
    private var body = Data(#"{"active":false}"#.utf8)
    private var lastRequest: Date?
    private var maxGap: TimeInterval = 0
    private var requests = 0
    private var version: String?

    public init() {}

    /// Replaces what GET /step returns.
    public func publish(_ step: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: step) else { return }
        lock.lock()
        body = data
        lock.unlock()
    }

    /// When the watch last polled, and the longest gap between polls and their count
    /// in the current watchapp session. A growing gap with the phone locked means iOS
    /// suspended the Pebble app. `version` is the watchapp's, from its last poll (`v`);
    /// nil before v0.4, which didn't send it.
    public var pollStats: (last: Date?, maxGap: TimeInterval, count: Int, version: String?) {
        lock.lock()
        defer { lock.unlock() }
        return (lastRequest, maxGap, requests, version)
    }

    /// Starts counting afresh, e.g. for a new trip. Keeps the last poll time, so the
    /// watch still shows as connected.
    public func resetStats() {
        lock.lock()
        maxGap = 0
        requests = 0
        lock.unlock()
    }

    /// Counts a poll and returns the time since the previous one, and the body to serve.
    func recordPoll(at now: Date, version: String? = nil) -> (gap: TimeInterval?, body: Data) {
        lock.lock()
        defer { lock.unlock() }
        let gap = lastRequest.map { now.timeIntervalSince($0) }
        if let gap, gap > Self.sessionGap {
            requests = 0
            maxGap = 0
        } else if let gap {
            maxGap = max(maxGap, gap)
        }
        lastRequest = now
        requests += 1
        self.version = version
        return (gap, body)
    }

    /// Starts listening if not already. Safe to call repeatedly, e.g. when the
    /// app returns to the foreground or a trip starts.
    public func start() {
        queue.async { self.startOnQueue() }
    }

    public func stop() {
        queue.async {
            self.listener?.cancel()
            self.listener = nil
        }
    }

    /// Replaces the listener with a new one. While the app is suspended (e.g. locked after
    /// a trip, with GPS off) iOS can tear down the socket without the listener reporting it,
    /// so `start()` would keep a dead listener. Call it when the app comes back.
    /// The new listener starts once the old one has let go of the port: binding it any
    /// sooner fails with "Address already in use".
    public func restart() {
        queue.async {
            guard let old = self.listener else { return self.startOnQueue() }
            self.listener = nil
            old.stateUpdateHandler = { [weak self] state in
                if case .cancelled = state { self?.startOnQueue() }
            }
            old.cancel()
            // In case the old listener never reports its cancellation (startOnQueue runs once).
            self.queue.asyncAfter(deadline: .now() + 1) { self.startOnQueue() }
        }
    }

    private func startOnQueue() {
        guard listener == nil else { return }
        onStateChange?(.starting)
        let params = NWParameters.tcp
        params.requiredInterfaceType = .loopback
        params.allowLocalEndpointReuse = true
        let listener: NWListener
        do {
            listener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: Self.port)!)
        } catch {
            onStateChange?(.failed(error.localizedDescription))
            restartSoon()
            return
        }
        listener.newConnectionHandler = { [weak self] connection in self?.serve(connection) }
        // iOS can tear down a listening socket (e.g. after the app was suspended);
        // restart instead of silently leaving the watch with nothing to reach.
        listener.stateUpdateHandler = { [weak self, weak listener] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.onStateChange?(.running)
            case .failed(let error), .waiting(let error):
                self.onStateChange?(.failed(error.localizedDescription))
                listener?.cancel()
                if self.listener === listener { self.listener = nil }
                self.restartSoon()
            case .cancelled where self.listener === listener:
                // Cancelled by the system, not by stop() or restart(), which clear it first.
                self.listener = nil
                self.restartSoon()
            default:
                break
            }
        }
        self.listener = listener
        listener.start(queue: queue)
    }

    private func restartSoon() {
        queue.asyncAfter(deadline: .now() + 2) { self.startOnQueue() }
    }

    private func serve(_ connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, _, _ in
            guard let self, let data, let request = String(data: data, encoding: .utf8) else {
                connection.cancel()
                return
            }
            // "GET /step?t=123&v=0.4 HTTP/1.1"
            let path = request.split(separator: " ").dropFirst().first.map(String.init) ?? ""
            let response: Data
            if path.hasPrefix("/step") {
                let now = Date()
                let version = URLComponents(string: path)?.queryItems?.first { $0.name == "v" }?.value
                let (gap, body) = self.recordPoll(at: now, version: version)
                self.onPoll?(now, gap)
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
