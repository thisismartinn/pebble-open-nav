import Foundation

public struct Coordinate: Equatable, Sendable {
    public var lat: Double
    public var lon: Double

    public init(lat: Double, lon: Double) {
        self.lat = lat
        self.lon = lon
    }

    /// Great-circle distance in metres.
    public func distance(to other: Coordinate) -> Double {
        let r = 6_371_000.0
        let dLat = (other.lat - lat) * .pi / 180
        let dLon = (other.lon - lon) * .pi / 180
        let a = sin(dLat / 2) * sin(dLat / 2)
            + cos(lat * .pi / 180) * cos(other.lat * .pi / 180) * sin(dLon / 2) * sin(dLon / 2)
        return 2 * r * atan2(sqrt(a), sqrt(1 - a))
    }
}

/// Projects `p` onto segment a-b. Returns the fraction along the segment (0...1)
/// and the distance from `p` to the segment in metres. Uses a local flat
/// approximation, which is accurate at the scale of route segments.
func project(_ p: Coordinate, onto a: Coordinate, _ b: Coordinate) -> (t: Double, distance: Double) {
    let kx = cos(a.lat * .pi / 180) * 111_320.0
    let ky = 110_540.0
    let bx = (b.lon - a.lon) * kx, by = (b.lat - a.lat) * ky
    let px = (p.lon - a.lon) * kx, py = (p.lat - a.lat) * ky
    let len2 = bx * bx + by * by
    let t = len2 > 0 ? min(max((px * bx + py * by) / len2, 0), 1) : 0
    let dx = px - t * bx, dy = py - t * by
    return (t, (dx * dx + dy * dy).squareRoot())
}

public enum Polyline {
    /// Decodes a Google-style encoded polyline. Valhalla uses 6 digits of precision.
    public static func decode(_ encoded: String, precision: Double = 1e6) -> [Coordinate] {
        let bytes = Array(encoded.utf8)
        var index = 0
        var lat = 0, lon = 0
        var coords: [Coordinate] = []

        func nextValue() -> Int? {
            var result = 0, shift = 0
            while index < bytes.count {
                let b = Int(bytes[index]) - 63
                index += 1
                result |= (b & 0x1f) << shift
                shift += 5
                if b < 0x20 {
                    return (result & 1) != 0 ? ~(result >> 1) : (result >> 1)
                }
            }
            return nil
        }

        while index < bytes.count {
            guard let dLat = nextValue(), let dLon = nextValue() else { break }
            lat += dLat
            lon += dLon
            coords.append(Coordinate(lat: Double(lat) / precision, lon: Double(lon) / precision))
        }
        return coords
    }
}
