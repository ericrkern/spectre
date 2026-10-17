import Foundation
import Testing
@testable import QuisPulsat

@Test func aStrongBluetoothSignalIsInsideOneHundredFeetAndAWeakOneIsNot() {
    let close = NearbyScan.bluetoothFeet(rssi: -59)
    #expect(abs(close - 3.280839895) < 0.01)
    #expect(NearbyScan.withinLimit(close))

    let mid = NearbyScan.bluetoothFeet(rssi: -80)
    #expect(NearbyScan.withinLimit(mid))
    #expect(mid > close)

    let far = NearbyScan.bluetoothFeet(rssi: -100)
    #expect(far > NearbyScan.standardFeet)
    #expect(NearbyScan.bluetooth(identifier: "far", name: "Far", rssi: -100, advertisement: "ad", seenAt: Date()) == nil)
    #expect(NearbyScan.bluetooth(identifier: "unknown", name: "Unknown", rssi: 127, advertisement: "ad", seenAt: Date()) == nil)
}

@Test func aCalibratedTransmitLevelReplacesTheDefaultReference() {
    #expect(NearbyScan.referenceRSSI(txPower: nil) == -59)
    #expect(NearbyScan.referenceRSSI(txPower: 4) == -59)
    #expect(NearbyScan.referenceRSSI(txPower: -40) == -40)
    let atOneMeter = NearbyScan.bluetoothFeet(rssi: -40, referenceRSSI: -40)
    #expect(abs(atOneMeter - 3.280839895) < 0.01)
}

@Test func nearbyDotsKeepEachSourceAndStayInsideOneHundredFeet() {
    let now = Date()
    let speaker = NearbyScan.bluetooth(
        identifier: "speaker",
        name: "Speaker",
        rssi: -70,
        advertisement: "Speaker · connectable",
        seenAt: now
    )
    let phone = NearbyScan.bluetooth(
        identifier: "phone",
        name: "",
        rssi: -85,
        advertisement: "advertisement",
        seenAt: now
    )
    let tag = NearbyScan.tag(records: "1 record", seenAt: now)
    let near = NearbyScan.proximity(near: true, seenAt: now)
    let away = NearbyScan.proximity(near: false, seenAt: now)
    let peer = NearbyScan.peer(feet: 40, bearing: .pi / 2, seenAt: now)
    let distantPeer = NearbyScan.peer(feet: 250, seenAt: now)

    #expect(speaker?.bearing == nil)
    #expect(tag.bearing == 0)
    #expect(tag.directionLabel == "Top of the phone")
    #expect(near?.bearing == 0)
    #expect(phone?.name == "Bluetooth phon")
    #expect(away == nil)
    #expect(distantPeer == nil)
    #expect(peer?.measured == true)
    #expect(tag.distanceLabel == "Within 1 ft")
    #expect(near?.distanceLabel == "Within 1 ft")

    let shown = NearbyScan.visible([speaker!, phone!, tag, near!, peer!], now: now)
    #expect(shown.count == 5)
    #expect(Set(shown.map(\.source)) == Set(NearbySource.allCases))
    #expect(shown.map(\.distanceFeet) == shown.map(\.distanceFeet).sorted())
    #expect(shown.filter { $0.source == .bluetooth }.count == 2)
    #expect(shown.allSatisfy { NearbyScan.withinLimit($0.distanceFeet) })
}

@Test func aSilentBluetoothDeviceLeavesAndATagStays() {
    let now = Date()
    let old = NearbyScan.bluetooth(
        identifier: "gone",
        name: "Gone",
        rssi: -60,
        advertisement: "ad",
        seenAt: now.addingTimeInterval(-30)
    )!
    let tag = NearbyScan.tag(records: "2 records", seenAt: now.addingTimeInterval(-30))
    let shown = NearbyScan.visible([old, tag], now: now)
    #expect(shown.map(\.source) == [.nfc])
}

@Test func theSensitivityDialChangesTheNearbyCircle() {
    #expect(DetectionSensitivity(level: 0).nearbyFeet == 1)
    #expect(DetectionSensitivity(level: 1).nearbyFeet == 100)
    #expect(abs(DetectionSensitivity(level: 0.5).nearbyFeet - 50.5) < 0.001)
    #expect(NearbyScan.rangeLabel(feet: 1) == "1 ft")
    #expect(NearbyScan.rangeLabel(feet: 100) == "100 ft")

    let now = Date()
    let nearer = NearbyScan.bluetooth(identifier: "mid", name: "Mid", rssi: -80, advertisement: "ad", seenAt: now)
    let feet = NearbyScan.bluetoothFeet(rssi: -80)
    #expect(feet > NearbyScan.minFeet)
    #expect(feet <= NearbyScan.maxFeet)
    #expect(nearer != nil)
    #expect(NearbyScan.visible([nearer!], now: now, rangeFeet: DetectionSensitivity(level: 0).nearbyFeet).isEmpty)
    #expect(NearbyScan.visible([nearer!], now: now, rangeFeet: DetectionSensitivity(level: 1).nearbyFeet).count == 1)
}

@Test func aDotSitsAheadOrToTheRightFromItsBearing() {
    let ahead = NearbyScan.plot(distanceFeet: 50, bearing: 0, rangeFeet: 100)
    #expect(abs((ahead?.x ?? 1)) < 0.001)
    #expect(abs((ahead?.y ?? 0) - 0.5) < 0.001)

    let right = NearbyScan.plot(distanceFeet: 50, bearing: .pi / 2, rangeFeet: 100)
    #expect(abs((right?.x ?? 0) - 0.5) < 0.001)
    #expect(abs(right?.y ?? 1) < 0.001)

    #expect(NearbyScan.plot(distanceFeet: 150, bearing: 0, rangeFeet: 100) == nil)
    #expect(NearbyScan.plot(distanceFeet: 40, bearing: nil, rangeFeet: 100) == nil)

    let onRing = NearbyScan.ringPoint(distanceFeet: 50, rangeFeet: 100, slot: 0, slots: 1)
    #expect(abs(hypot(onRing?.x ?? 0, onRing?.y ?? 0) - 0.5) < 0.001)
}
