import Foundation
import Testing
@testable import QuisPulsat

private func room(depth: Double, confidence: Int = 2) -> [DepthCell] {
    Array(repeating: DepthCell(depth: depth, confidence: confidence), count: 12)
}

@Test func aFarDepthDrawsOneWallAndOneCombinedDot() {
    let picture = RoomSurvey.picture(
        cells: room(depth: 3),
        columns: 4,
        rows: 3,
        sightings: [],
        wifiName: nil,
        rangeFeet: 100
    )
    #expect(picture.walls.count == 1)
    #expect(picture.walls.first?.count == 4)
    #expect(picture.furnishings.isEmpty)
    #expect(picture.dot != nil)
    #expect(abs(picture.dot?.bearing ?? 1) < 0.02)
    let feet = picture.dot?.feet ?? 0
    #expect(feet > 9)
    #expect(feet < 10)
    #expect(picture.lines.contains("Wi-Fi reads the joined network"))
    #expect(picture.walls.first?.first?.bearing ?? 0 < 0)
    #expect(picture.walls.first?.last?.bearing ?? 0 > 0)
}

@Test func aCloserDepthDrawsANearBorderInsideTheWall() {
    var cells = room(depth: 3)
    cells[1] = DepthCell(depth: 1, confidence: 2)
    let picture = RoomSurvey.picture(
        cells: cells,
        columns: 4,
        rows: 3,
        sightings: [],
        wifiName: "Hall",
        rangeFeet: 100
    )
    #expect(picture.furnishings.count == 1)
    #expect((picture.furnishings.first?.first?.feet ?? 0) < (picture.walls.first?.first?.feet ?? 0))
    #expect(picture.dot != nil)
    #expect(picture.lines.contains("Wi-Fi Hall"))
}

@Test func theCombinedDotFollowsADeviceAndDropsWhatIsOutOfRange() {
    let now = Date()
    let peer = NearbyScan.peer(feet: 6, bearing: .pi / 2, seenAt: now)!
    let withDevice = RoomSurvey.picture(
        cells: room(depth: 3),
        columns: 4,
        rows: 3,
        sightings: [peer],
        wifiName: nil,
        rangeFeet: 100
    )
    #expect((withDevice.dot?.bearing ?? 0) > 0)

    let tooFar = RoomSurvey.picture(
        cells: room(depth: 3),
        columns: 4,
        rows: 3,
        sightings: [],
        wifiName: nil,
        rangeFeet: 5
    )
    #expect(tooFar.walls.isEmpty)
    #expect(tooFar.dot == nil)
}

@Test func wallsStayUpUntilTheGpsMoves() {
    func picture(depth: Double, sightings: [NearbySighting] = []) -> RoomPicture {
        RoomSurvey.picture(
            cells: depth > 0 ? room(depth: depth) : [],
            columns: 4,
            rows: 3,
            sightings: sightings,
            wifiName: nil,
            rangeFeet: 100
        )
    }

    var hold = RoomSurvey.Hold()
    let first = hold.apply(to: picture(depth: 3))
    let replaced = hold.apply(to: picture(depth: 1))
    #expect(replaced.walls == first.walls)
    #expect((replaced.walls.first?.first?.feet ?? 0) > 9)

    let here = SurveyPlace(latitude: 40, longitude: -74, accuracyMeters: 5)
    let jitter = SurveyPlace(latitude: 40 + (5 / 111_320), longitude: -74, accuracyMeters: 5)
    let loose = SurveyPlace(latitude: 40 + (20 / 111_320), longitude: -74, accuracyMeters: 30)
    let away = SurveyPlace(latitude: 40 + (20 / 111_320), longitude: -74, accuracyMeters: 5)
    #expect(RoomSurvey.placeChanged(from: here, to: jitter) == false)
    #expect(RoomSurvey.placeChanged(from: here, to: loose) == false)
    #expect(RoomSurvey.placeChanged(from: here, to: away))

    let stayed = hold.note(place: here)
    let jittered = hold.note(place: jitter)
    #expect(stayed == false)
    #expect(jittered == false)
    let peer = NearbyScan.peer(feet: 6, bearing: .pi / 2, seenAt: Date())!
    let withPeer = hold.apply(to: picture(depth: 1, sightings: [peer]))
    #expect(withPeer.walls == first.walls)
    #expect(withPeer.lines.contains { $0.contains("Ultra Wideband peer") })

    let moved = hold.note(place: away)
    #expect(moved)
    let cleared = hold.apply(to: picture(depth: 0))
    #expect(cleared.walls.isEmpty)
    let next = hold.apply(to: picture(depth: 1))
    #expect((next.walls.first?.first?.feet ?? 0) < 4)
}
