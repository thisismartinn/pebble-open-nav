import Foundation

/// Our own short turn instructions, built from the Valhalla maneuver type and street
/// name: "Turn right onto Cầu Bươu" rather than Valhalla's "Turn right onto Đường Cầu
/// Bươu/ĐT.70. Continue on ĐT.70.", which doesn't fit the watch.
public enum InstructionText {
    /// - Parameters:
    ///   - next: the maneuver after `m`. For a roundabout, its exit maneuver names the
    ///     road the rider leaves on.
    ///   - vietnamese: the route's language; otherwise English.
    public static func text(for m: ValhallaManeuver, next: ValhallaManeuver? = nil,
                            vietnamese: Bool) -> String {
        var street = Self.street(m)
        // With a street the text is "<action> <connector> <street>", without one just the action.
        let phrase: (action: String, connector: String)
        switch m.type {
        case 10: phrase = vietnamese ? ("Rẽ phải", "vào") : ("Turn right", "onto")
        case 15: phrase = vietnamese ? ("Rẽ trái", "vào") : ("Turn left", "onto")
        case 9: phrase = vietnamese ? ("Chếch phải", "vào") : ("Bear right", "onto")
        case 16: phrase = vietnamese ? ("Chếch trái", "vào") : ("Bear left", "onto")
        case 11: phrase = vietnamese ? ("Rẽ gắt phải", "vào") : ("Sharp right", "onto")
        case 14: phrase = vietnamese ? ("Rẽ gắt trái", "vào") : ("Sharp left", "onto")
        case 12, 13: phrase = vietnamese ? ("Quay đầu", "tại") : ("U-turn", "at")
        case 23: phrase = vietnamese ? ("Giữ bên phải", "vào") : ("Keep right", "on")
        case 24: phrase = vietnamese ? ("Giữ bên trái", "vào") : ("Keep left", "on")
        case 7, 8, 22: phrase = vietnamese ? ("Đi thẳng", "vào") : ("Continue", "on")
        case 17, 18, 19: phrase = vietnamese ? ("Vào đường dẫn", "lên") : ("Take the ramp", "to")
        case 20, 21: phrase = vietnamese ? ("Rẽ ra", "") : ("Exit", "to")
        case 25, 37, 38:
            // "Nhập vào" needs a road after it; on its own it's "Nhập làn"
            phrase = vietnamese ? (street == nil ? "Nhập làn" : "Nhập", "vào") : ("Merge", "onto")
        case 26:
            guard let n = m.roundaboutExitCount else { return valhallaText(m) }
            // The roundabout's own names are the ring's, not the road it leads to.
            street = next.flatMap { $0.type == 27 ? Self.street($0) : nil }
            phrase = vietnamese ? ("Vòng xuyến: lối ra thứ \(n)", "vào") : ("Roundabout: exit \(n)", "onto")
        case 28:
            return vietnamese ? "Lên phà" : "Take the ferry"
        case 4:
            return vietnamese ? "Điểm đến ở phía trước" : "Destination ahead"
        case 5:
            return vietnamese ? "Điểm đến ở bên phải" : "Destination on the right"
        case 6:
            return vietnamese ? "Điểm đến ở bên trái" : "Destination on the left"
        case 1, 2, 3:
            guard let street else { return valhallaText(m) }
            return vietnamese ? "Đi theo \(street)" : "Go along \(street)"
        default:
            return valhallaText(m)
        }
        guard let street else { return phrase.action }
        return [phrase.action, phrase.connector, street].filter { !$0.isEmpty }.joined(separator: " ")
    }

    /// Valhalla's own text, for maneuvers we have no phrase for. The spoken alert is
    /// the shorter one: it leaves out the "Continue on …" that may follow the turn.
    static func valhallaText(_ m: ValhallaManeuver) -> String {
        var text = (m.verbalTransitionAlertInstruction ?? m.instruction).trimmingCharacters(in: .whitespaces)
        if text.hasSuffix(".") { text.removeLast() }
        return text
    }

    /// The road a maneuver turns onto: the names where it starts when Valhalla gives
    /// those (they can differ from the names along the rest of the maneuver), a real
    /// name rather than a road number, without the "Đường"/"Phố" most streets start with.
    static func street(_ m: ValhallaManeuver) -> String? {
        let names = (m.beginStreetNames ?? m.streetNames ?? []).flatMap(splitNames)
        guard var name = names.first(where: { !isRoadNumber($0) }) ?? names.first else { return nil }
        // "Cầu vượt Nguyễn Chí Thanh - Trần Duy Hưng": the first part is enough
        if let dash = name.range(of: " - ") { name = String(name[..<dash.lowerBound]) }
        // "Ngõ", "Ngách" and "Hẻm" stay: they go with the alley number. So does the prefix
        // when what follows isn't a name of two words or more: "Đường Số 1" and "Phố 8 Tháng 3"
        // (a house number or a date), "Đường tỉnh 70" and "Đường gom …" (a kind of road),
        // and "Phố Huế" or "Đường Láng" (a city, or too short to read as a street).
        if let prefix = ["Đường ", "Phố "].first(where: name.hasPrefix) {
            let rest = name.dropFirst(prefix.count)
            if let first = rest.first, first.isUppercase, !rest.hasPrefix("Số "), rest.contains(" ") {
                name = String(rest)
            }
        }
        return name
    }

    /// "QL.21C/Đường Phạm Tu" → ["QL.21C", "Đường Phạm Tu"]. A "/" between two digits is
    /// part of a number ("Ngõ 12/5", "Phố 8/3"), not a separator.
    static func splitNames(_ names: String) -> [String] {
        names.replacingOccurrences(of: "(?<![0-9])/|/(?![0-9])", with: "\n", options: .regularExpression)
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// Road numbers such as "QL.21C", "ĐT.70", "CT.01", "AH1" or "I-95".
    static func isRoadNumber(_ name: String) -> Bool {
        name.range(of: "^[A-ZĐ]{1,3}[ .-]?[0-9]+[A-Z]?$", options: .regularExpression) != nil
    }
}
