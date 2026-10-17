import Foundation
import Testing
@testable import QuisPulsat

private func openRoom(depth: Double = 2, confidence: Int = 2) -> [DepthCell] {
    Array(repeating: DepthCell(depth: depth, confidence: confidence), count: DepthDetector.columns * DepthDetector.rows)
}

private func learnDepth(_ detector: inout DepthDetector, cells: [DepthCell]) {
    for timestamp in stride(from: 0.0, through: 5.0, by: 0.5) {
        _ = detector.ingest(DepthFrame(timestamp: timestamp, cells: cells))
    }
    #expect(detector.phase == .watching)
}

@Test func somethingEnteringEmptySpaceIsADepthHit() {
    var detector = DepthDetector()
    learnDepth(&detector, cells: openRoom())
    var entered = openRoom()
    entered[0] = DepthCell(depth: 1.1, confidence: 2)
    let hits = detector.ingest(DepthFrame(timestamp: 6, cells: entered))
    #expect(hits.map(\.feature) == ["Empty space"])
    #expect(abs(hits[0].magnitude - 0.9) < 0.001)
    #expect(hits[0].detail == "confidence 2")
    #expect(hits[0].kind == .depth)
}

@Test func aSmallDepthChangeAndALowConfidenceCellStayQuiet() {
    var detector = DepthDetector()
    learnDepth(&detector, cells: openRoom())
    var nearer = openRoom()
    nearer[3] = DepthCell(depth: 1.8, confidence: 2)
    #expect(detector.ingest(DepthFrame(timestamp: 6, cells: nearer)).isEmpty)

    var uncertainDetector = DepthDetector()
    let uncertain = openRoom(confidence: 0)
    learnDepth(&uncertainDetector, cells: uncertain)
    var entered = uncertain
    entered[1] = DepthCell(depth: 0.4, confidence: 2)
    #expect(uncertainDetector.ingest(DepthFrame(timestamp: 6, cells: entered)).isEmpty)
}

@Test func aRadioAlreadyInTheRoomIsNotANewAdvertisement() {
    var detector = RadioDetector()
    let known = RadioFrame(timestamp: 0, identifier: "watch", rssi: -70, advertisement: "mfr 4 bytes")
    _ = detector.ingest(known)
    _ = detector.ingest(RadioFrame(timestamp: 5, identifier: "watch", rssi: -68, advertisement: "mfr 4 bytes"))
    #expect(detector.phase == .watching)
    let again = detector.ingest(RadioFrame(timestamp: 6, identifier: "watch", rssi: -67, advertisement: "mfr 4 bytes"))
    #expect(again.isEmpty)
}

@Test func aNewAdvertisementAndASharpRssiChangeStaySeparateLeads() {
    var detector = RadioDetector()
    _ = detector.ingest(RadioFrame(timestamp: 0, identifier: "lamp", rssi: -80, advertisement: "advertisement"))
    _ = detector.ingest(RadioFrame(timestamp: 5, identifier: "lamp", rssi: -80, advertisement: "advertisement"))
    let arrival = detector.ingest(RadioFrame(
        timestamp: 6,
        identifier: "tracker",
        rssi: -55,
        advertisement: "FDEE · mfr 8 bytes"
    ))
    #expect(arrival.map(\.feature) == ["New advertisement"])
    #expect(arrival[0].magnitude == -55)
    #expect(arrival[0].detail == "FDEE · mfr 8 bytes")
    #expect(arrival[0].thresholdLabel == "New")

    let jump = detector.ingest(RadioFrame(timestamp: 7, identifier: "lamp", rssi: -60, advertisement: "advertisement"))
    #expect(jump.map(\.feature) == ["RSSI change"])
    #expect(jump[0].magnitude == 20)
    #expect(jump[0].kind == .radio)
    #expect(arrival[0].kind != jump[0].kind || arrival[0].feature != jump[0].feature)
}
