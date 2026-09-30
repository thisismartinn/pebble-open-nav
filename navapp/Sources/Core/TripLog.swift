import Foundation

/// One CSV file per trip in the app's Caches directory (the last five trips are
/// kept), for looking into a ride afterwards: GPS fixes, what guidance made of
/// them, what was published to the watch and when the watch polled. It never
/// leaves the phone unless the user shares it.
///
/// Every row is written straight to the file, so if iOS kills the app only the
/// row being written is lost. Safe to call from any thread.
public final class TripLog: @unchecked Sendable {
    public static let keep = 5
    static let header = "time,event,lat,lon,accuracy,speed,course,along,to_maneuver,maneuver_index,from_route,reroute,detail"

    public let url: URL
    private let queue = DispatchQueue(label: "TripLog")
    private var handle: FileHandle?

    /// Starts a new log, deleting the oldest so that at most `keep` remain.
    /// - Parameter directory: defaults to Caches/TripLogs.
    public init?(destination: String, detail: String = "", directory: URL? = nil, now: Date = Date()) {
        let fm = FileManager.default
        guard let dir = directory ?? fm.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("TripLogs", isDirectory: true) else { return nil }
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let name = "PebbleOpenNav-\(Self.fileDate.string(from: now)).csv"
        url = dir.appendingPathComponent(name)
        let old = ((try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "csv" && $0.lastPathComponent != name }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }  // names sort by date
        for file in old.dropLast(Self.keep - 1) { try? fm.removeItem(at: file) }
        guard fm.createFile(atPath: url.path, contents: Data((Self.header + "\n").utf8)),
              let handle = try? FileHandle(forWritingTo: url) else { return nil }
        handle.seekToEndOfFile()
        self.handle = handle
        event("start", "\(destination) · \(Self.isoDate.string(from: now))\(detail.isEmpty ? "" : " · " + detail)", time: now)
    }

    /// A GPS fix as delivered by Core Location; `time` is the fix's own timestamp.
    public func fix(time: Date, lat: Double, lon: Double, accuracy: Double, speed: Double, course: Double,
                    detail: String = "") {
        let columns = [String(format: "%.7f", lat), String(format: "%.7f", lon)]
            + [accuracy, speed, course].map(Self.number) + ["", "", "", "", ""]
        row(time, "fix", columns, detail)
    }

    /// What guidance made of a fix.
    public func guidance(_ u: GuidanceUpdate) {
        let columns = ["", "", "", Self.number(u.speed), "", Self.number(u.along), Self.number(u.distanceToManeuver),
                       String(u.maneuverIndex), Self.number(u.distanceFromRoute), u.needsReroute ? "1" : "0"]
        row(u.fixTime, "guidance", columns, u.arrived ? "arrived" : "")
    }

    /// A payload handed to the step server, as JSON.
    public func publish(_ payload: [String: Any], time: Date = Date()) {
        let json = (try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]))
            .flatMap { String(data: $0, encoding: .utf8) } ?? ""
        row(time, "publish", Array(repeating: "", count: 10), json)
    }

    /// The watchapp fetched /step; `gap` is the time since its previous fetch.
    public func poll(time: Date, gap: TimeInterval?) {
        row(time, "poll", Array(repeating: "", count: 10), gap.map { "gap " + Self.number($0) + "s" } ?? "first")
    }

    /// Anything else: route, reroute, end of the trip.
    public func event(_ name: String, _ detail: String = "", time: Date = Date()) {
        row(time, name, Array(repeating: "", count: 10), detail)
    }

    /// Writes a last row and closes the file. Later calls are ignored.
    public func close(_ detail: String = "", time: Date = Date()) {
        event("close", detail, time: time)
        queue.async {
            try? self.handle?.close()
            self.handle = nil
        }
    }

    private func row(_ time: Date, _ event: String, _ columns: [String], _ detail: String) {
        let line = ([String(format: "%.3f", time.timeIntervalSince1970), event] + columns + [Self.quoted(detail)])
            .joined(separator: ",") + "\n"
        queue.async { try? self.handle?.write(contentsOf: Data(line.utf8)) }
    }

    private static func number(_ value: Double) -> String {
        value.isFinite ? String(format: "%.2f", value) : ""
    }

    private static func quoted(_ text: String) -> String {
        guard text.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" }) else { return text }
        return "\"" + text.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    private static let fileDate: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd-HHmmss"
        return f
    }()

    private static let isoDate: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.timeZone = .current
        return f
    }()
}
