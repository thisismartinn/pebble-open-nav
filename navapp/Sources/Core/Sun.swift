import Foundation

/// Sunrise and sunset from the standard sunrise equation (accurate to a minute
/// or two), used to switch the watch to its light theme during the day.
public enum Sun {
    /// Sunrise and sunset around the given Julian day number. During polar day
    /// the interval covers all time; during polar night it is empty.
    static func times(julianDay n: Double, at c: Coordinate) -> (rise: Date, set: Date) {
        let rad = Double.pi / 180
        let meanNoon = n - c.lon / 360
        let m = (357.5291 + 0.98560028 * meanNoon).truncatingRemainder(dividingBy: 360)
        let center = 1.9148 * sin(m * rad) + 0.0200 * sin(2 * m * rad) + 0.0003 * sin(3 * m * rad)
        let lambda = (m + center + 180 + 102.9372).truncatingRemainder(dividingBy: 360)
        let transit = 2451545.0 + meanNoon + 0.0053 * sin(m * rad) - 0.0069 * sin(2 * lambda * rad)
        let sinDecl = sin(lambda * rad) * sin(23.4397 * rad)
        let cosDecl = cos(asin(sinDecl))
        let cosHour = (sin(-0.833 * rad) - sin(c.lat * rad) * sinDecl) / (cos(c.lat * rad) * cosDecl)
        if cosHour < -1 { return (.distantPast, .distantFuture) }  // polar day
        if cosHour > 1 { return (.distantFuture, .distantFuture) }  // polar night
        let hour = acos(cosHour) / rad / 360
        func date(_ julian: Double) -> Date { Date(timeIntervalSince1970: (julian - 2440587.5) * 86400) }
        return (date(transit - hour), date(transit + hour))
    }

    /// Whether the sun is up at `date` at `c`.
    public static func isUp(at date: Date, at c: Coordinate) -> Bool {
        let julian = date.timeIntervalSince1970 / 86400 + 2440587.5
        let n = (julian - 2451545.0 + 0.0008).rounded(.up)
        // Check the neighbouring days too: the UTC day and the local day differ
        // for part of every day away from Greenwich.
        return [-1.0, 0, 1].contains { offset in
            let t = times(julianDay: n + offset, at: c)
            return date >= t.rise && date < t.set
        }
    }
}
