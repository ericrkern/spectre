import Foundation

enum NearbySource: String, Equatable, Hashable, CaseIterable {
    case bluetooth
    case nfc
    case ultraWideband
    case proximity

    var title: String {
        switch self {
        case .bluetooth: "Bluetooth"
        case .nfc: "NFC"
        case .ultraWideband: "Ultra Wideband"
        case .proximity: "Proximity"
        }
    }

    var rangeNote: String {
        switch self {
        case .bluetooth:
            "Estimated from signal strength. Bluetooth does not report a direction, so this dot only marks distance."
        case .nfc:
            "Read at the top of the phone. The dot sits at the top of the circle."
        case .ultraWideband:
            "Measured distance and direction to a peer in a session with this phone. Up on the circle is the top of the phone."
        case .proximity:
            "The earpiece is at the top of the phone. The dot sits at the top of the circle."
        }
    }
}

struct NearbySighting: Identifiable, Equatable, Hashable {
    var id: String
    var source: NearbySource
    var name: String
    var distanceFeet: Double
    var measured: Bool
    var signal: String
    var note: String
    var seenAt: Date
    /// Radians clockwise from the top of the phone. Nil when this sensor does not report a direction.
    var bearing: Double?

    var distanceLabel: String {
        if distanceFeet < 1 {
            return "Within 1 ft"
        }
        if measured {
            return String(format: "%.0f ft measured", distanceFeet.rounded())
        }
        return String(format: "%.0f ft estimated", distanceFeet.rounded())
    }

    var directionLabel: String {
        NearbyScan.directionLabel(bearing)
    }
}

enum NearbyScan {
    static let minFeet = 1.0
    static let maxFeet = 100.0
    static var standardFeet: Double { maxFeet }

    static func directionLabel(_ bearing: Double?) -> String {
        guard let bearing else { return "Not reported" }
        var degrees = bearing * 180 / .pi
        degrees = degrees.truncatingRemainder(dividingBy: 360)
        if degrees < 0 { degrees += 360 }
        if degrees < 20 || degrees > 340 { return "Top of the phone" }
        if abs(degrees - 180) < 20 { return "Bottom of the phone" }
        if abs(degrees - 90) < 20 { return "Right of the phone" }
        if abs(degrees - 270) < 20 { return "Left of the phone" }
        if degrees < 180 {
            return String(format: "%.0f° right of the top", degrees)
        }
        return String(format: "%.0f° left of the top", 360 - degrees)
    }
    static let staleBluetooth: TimeInterval = 12
    private static let feetPerMeter = 3.280839895

    /// Log-distance estimate. `referenceRSSI` is the level at 1 meter, defaulting to −59 dBm.
    static func bluetoothFeet(rssi: Double, referenceRSSI: Double = -59, exponent: Double = 2.2) -> Double {
        let meters = pow(10, (referenceRSSI - rssi) / (10 * exponent))
        return meters * feetPerMeter
    }

    static func withinLimit(_ feet: Double, rangeFeet: Double = standardFeet) -> Bool {
        feet >= 0 && feet <= rangeFeet
    }

    static func rangeLabel(feet: Double) -> String {
        if abs(feet - feet.rounded()) < 0.05 {
            return "\(Int(feet.rounded())) ft"
        }
        return String(format: "%.1f ft", feet)
    }

    static func referenceRSSI(txPower: Double?) -> Double {
        guard let txPower, txPower <= -20, txPower >= -90 else { return -59 }
        return txPower
    }

    static func bluetooth(
        identifier: String,
        name: String,
        rssi: Double,
        txPower: Double? = nil,
        advertisement: String,
        seenAt: Date
    ) -> NearbySighting? {
        guard rssi < 0 else { return nil }
        let feet = bluetoothFeet(rssi: rssi, referenceRSSI: referenceRSSI(txPower: txPower))
        guard withinLimit(feet, rangeFeet: maxFeet) else { return nil }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let display = trimmed.isEmpty ? "Bluetooth \(identifier.prefix(4))" : trimmed
        return NearbySighting(
            id: "bluetooth-\(identifier)",
            source: .bluetooth,
            name: display,
            distanceFeet: feet,
            measured: false,
            signal: String(format: "%.0f dBm", rssi),
            note: advertisement,
            seenAt: seenAt,
            bearing: nil
        )
    }

    static func tag(records: String, seenAt: Date) -> NearbySighting {
        NearbySighting(
            id: "nfc-tag",
            source: .nfc,
            name: "NFC tag",
            distanceFeet: 0.2,
            measured: false,
            signal: records,
            note: "Read at the top of the phone.",
            seenAt: seenAt,
            bearing: 0
        )
    }

    static func peer(feet: Double, bearing: Double? = nil, seenAt: Date) -> NearbySighting? {
        guard withinLimit(feet, rangeFeet: maxFeet) else { return nil }
        return NearbySighting(
            id: "uwb-peer",
            source: .ultraWideband,
            name: "Ultra Wideband peer",
            distanceFeet: feet,
            measured: true,
            signal: String(format: "%.1f ft", feet),
            note: "A peer in a Nearby Interaction session.",
            seenAt: seenAt,
            bearing: bearing
        )
    }

    static func proximity(near: Bool, seenAt: Date) -> NearbySighting? {
        guard near else { return nil }
        return NearbySighting(
            id: "proximity-earpiece",
            source: .proximity,
            name: "Proximity",
            distanceFeet: 0.2,
            measured: false,
            signal: "Near",
            note: "Something is covering the earpiece.",
            seenAt: seenAt,
            bearing: 0
        )
    }

    /// Unit circle, y up. Bearing 0 is the top of the phone and increases clockwise.
    /// Nil when the distance is outside the circle or the sensor did not report a direction.
    static func plot(distanceFeet: Double, bearing: Double?, rangeFeet: Double) -> (x: Double, y: Double)? {
        guard let bearing, rangeFeet > 0, withinLimit(distanceFeet, rangeFeet: rangeFeet) else { return nil }
        let radius = distanceFeet / rangeFeet
        return (sin(bearing) * radius, cos(bearing) * radius)
    }

    /// A tap point on the distance ring for a sensor that did not report a direction.
    static func ringPoint(distanceFeet: Double, rangeFeet: Double, slot: Int, slots: Int) -> (x: Double, y: Double)? {
        guard slots > 0 else { return nil }
        let bearing = (Double(slot) + 0.5) / Double(slots) * 2 * .pi
        return plot(distanceFeet: distanceFeet, bearing: bearing, rangeFeet: rangeFeet)
    }

    /// Bluetooth drops out of the scan after it stops advertising. The other sources stay until they clear.
    static func visible(_ sightings: [NearbySighting], now: Date, rangeFeet: Double = standardFeet) -> [NearbySighting] {
        sightings
            .filter { sighting in
                guard withinLimit(sighting.distanceFeet, rangeFeet: rangeFeet) else { return false }
                if sighting.source == .bluetooth {
                    return now.timeIntervalSince(sighting.seenAt) <= staleBluetooth
                }
                return true
            }
            .sorted { lhs, rhs in
                if lhs.distanceFeet == rhs.distanceFeet {
                    return lhs.id < rhs.id
                }
                return lhs.distanceFeet < rhs.distanceFeet
            }
    }
}
