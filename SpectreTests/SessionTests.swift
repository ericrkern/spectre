import CoreBluetooth
import CoreLocation
import CoreMotion
import AVFoundation
import Foundation
import Testing
@testable import Spectre

@Test func elapsedFormatShowsMinutesSecondsAndTenths() {
    #expect(ElapsedTimeFormat.string(for: .seconds(0)) == "0:00.0")
    #expect(ElapsedTimeFormat.string(for: .seconds(75) + .milliseconds(400)) == "1:15.4")
    #expect(ElapsedTimeFormat.string(for: .seconds(3600 + 62) + .milliseconds(100)) == "1:01:02.1")
}

@Test func sampleTimeUsesTheSessionOriginAndWallClock() {
    let clock = ContinuousClock()
    let origin = clock.now
    let wallStart = Date(timeIntervalSince1970: 1_700_000_000)
    let sessionClock = SessionClock(origin: origin, wallClockStart: wallStart)
    let sample = sessionClock.sampleTime(at: origin, wallTime: wallStart)
    #expect(sample.elapsed == .zero)
    #expect(sample.wallTime == wallStart)
}

@Test func aHigherWidgetReadingPlaysAHigherAndLouderTone() {
    #expect(WidgetTone.pitch(1) > WidgetTone.pitch(0.5))
    #expect(WidgetTone.pitch(0.5) > WidgetTone.pitch(0))
    #expect(abs(WidgetTone.pitch(0) - WidgetTone.lowPitch) < 0.001)
    #expect(abs(WidgetTone.pitch(1) - WidgetTone.highPitch) < 0.001)
    #expect(WidgetTone.volume(1) > WidgetTone.volume(0.4))
    #expect(WidgetTone.volume(0.4) > WidgetTone.volume(0))
    #expect(WidgetTone.pitch(1.4) == WidgetTone.pitch(1))
    #expect(WidgetTone.volume(-0.2) == WidgetTone.volume(0))

    let full = SensorWidgetState(kind: .magnetometer, status: .live, value: "100 µT", reading: 100)
    let half = SensorWidgetState(kind: .magnetometer, status: .live, value: "50 µT", reading: 50)
    #expect(WidgetMetric.level(full) == 1)
    #expect(WidgetMetric.level(half) == 0.5)
    #expect(WidgetTone.pitch(WidgetMetric.level(full) ?? 0) > WidgetTone.pitch(WidgetMetric.level(half) ?? 0))
    #expect(WidgetMetric.level(SensorWidgetState(kind: .microphone, status: .live, value: "0 dB", reading: 0)) == 1)
    #expect(WidgetMetric.level(SensorWidgetState(kind: .compass, status: .live, value: "90°", reading: 90)) == nil)
    #expect(WidgetMetric.level(SensorWidgetState(kind: .magnetometer, status: .unavailable, value: "—", reading: 80)) == nil)
}

@Test func aLowerWidgetReadingDropsThePitchAndTheVolume() {
    let highPitch = WidgetTone.pitch(0.8)
    let highVolume = WidgetTone.volume(0.8)
    #expect(highPitch > WidgetTone.pitch(0.2))
    #expect(highVolume > WidgetTone.volume(0.2))
    #expect(WidgetMetric.level(SensorWidgetState(kind: .nearby, status: .live, value: "4 nearby", reading: 4)) == 0.5)
}

@Test func dialScalesPlaceTheNeedleOnTheReading() {
    #expect(DialScale.motion(0.5) == 0.5)
    #expect(DialScale.motion(2) == 1)
    #expect(DialScale.field(50) == 0.5)
    #expect(abs(DialScale.pressure(101) - 0.5) < 0.001)
    #expect(DialScale.sound(-40) == 0.5)
    #expect(DialScale.brightness(255) == 1)
    #expect(DialScale.depth(2.5) == 0.5)
    #expect(DialScale.steps(50) == 0.5)
    #expect(DialScale.steps(140) == 1)
    #expect(DialScale.acceleration(1) == 0.5)
    #expect(DialScale.rotation(2.5) == 0.5)
    #expect(DialScale.altitude(500) == 0.5)
    #expect(DialScale.pace(1) == 0.5)
}

@MainActor
@Test func focusingASensorMovesItToTheCenter() {
    let controller = DashboardController(
        feed: SensorFeed(widgets: SensorWidgetState.inventory(from: [:]))
    )
    #expect(controller.featuredKind == .survey)
    controller.focus(.barometer)
    #expect(controller.featuredKind == .barometer)
    controller.focus(.thermal)
    #expect(controller.featuredKind == .thermal)
}

@Test func sensorValuesIncludeUnits() {
    #expect(SensorValueFormat.g(0.042) == "0.04 g")
    #expect(SensorValueFormat.microtesla(48.26) == "48.3 µT")
    #expect(SensorValueFormat.kilopascals(101.325) == "101.33 kPa")
    #expect(SensorValueFormat.degrees(182.2) == "182°")
    #expect(SensorValueFormat.nearby(1) == "1 nearby")
    #expect(SensorValueFormat.nearby(3) == "3 nearby")
    #expect(SensorValueFormat.radiansPerSecond(1.25) == "1.25 rad/s")
    #expect(SensorValueFormat.pace(0.75) == "0.75 s/m")
}

@Test func inventoryKeepsEverySensorVisible() {
    let readings: [SensorKind: SensorReading] = [
        .deviceMotion: SensorReading(hardwarePresent: true, permission: .notRequired),
        .magnetometer: SensorReading(hardwarePresent: false, permission: .notRequired),
        .barometer: SensorReading(hardwarePresent: true, permission: .notRequired),
        .pedometer: SensorReading(hardwarePresent: true, permission: .notAsked),
        .compass: SensorReading(hardwarePresent: true, permission: .denied),
        .microphone: SensorReading(hardwarePresent: true, permission: .notAsked),
        .camera: SensorReading(hardwarePresent: true, permission: .allowed),
        .lidar: SensorReading(hardwarePresent: false, permission: .notAsked),
        .bluetooth: SensorReading(hardwarePresent: true, permission: .notAsked),
        .location: SensorReading(hardwarePresent: true, permission: .allowed),
    ]
    let widgets = SensorWidgetState.inventory(from: readings)

    #expect(widgets.map(\.kind) == SensorKind.board)
    #expect(widgets.contains { $0.kind == .nearby })
    #expect(widgets.allSatisfy { !$0.kind.isNearbySource })
    #expect(widgets.first { $0.kind == .deviceMotion }?.status == .live)
    #expect(widgets.first { $0.kind == .magnetometer }?.status == .unavailable)
    #expect(widgets.first { $0.kind == .magnetometer }?.displayedValue == "—")
    #expect(widgets.first { $0.kind == .compass }?.status == .denied)
    #expect(widgets.first { $0.kind == .compass }?.displayedValue == "Omitted")
    #expect(widgets.first { $0.kind == .pedometer }?.displayedValue == "Tap to allow")
    #expect(widgets.first { $0.kind == .camera }?.status == .live)
    #expect(widgets.first { $0.kind == .lidar }?.status == .unavailable)
}

@Test func missingReadingIsUnavailable() {
    let status = SensorStatus.resolve(SensorReading(hardwarePresent: false, permission: .allowed))
    #expect(status == .unavailable)
}

@Test func permissionMappingDoesNotTreatUndeterminedAsDenied() {
    #expect(DeviceSensorProbe.permission(from: CMAuthorizationStatus.notDetermined) == .notAsked)
    #expect(DeviceSensorProbe.permission(from: CMAuthorizationStatus.denied) == .denied)
    #expect(DeviceSensorProbe.permission(from: CLAuthorizationStatus.authorizedWhenInUse) == .allowed)
    #expect(DeviceSensorProbe.permission(from: CLAuthorizationStatus.denied) == .denied)
    #expect(DeviceSensorProbe.permission(from: AVAuthorizationStatus.notDetermined) == .notAsked)
    #expect(DeviceSensorProbe.permission(from: AVAudioApplication.recordPermission.denied) == .denied)
    #expect(DeviceSensorProbe.permission(from: CBManagerAuthorization.allowedAlways) == .allowed)
    #expect(DeviceSensorProbe.permission(from: CBManagerAuthorization.notDetermined) == .notAsked)
}

@MainActor
@Test func captureSavesTheLiveWidgetsWithoutChangingThem() {
    let feed = SensorFeed(widgets: [
        SensorWidgetState(kind: .deviceMotion, status: .live, value: "0.02 g"),
        SensorWidgetState(kind: .magnetometer, status: .unavailable, value: "—"),
    ])
    let store = MemoryCaptureStore()
    let controller = DashboardController(feed: feed, store: store)
    controller.placeName = "  Hallway  "
    controller.activate()
    #expect(controller.canCapture)
    controller.capture()
    #expect(store.captures.count == 1)
    #expect(store.captures[0].placeName == "Hallway")
    #expect(store.captures[0].sensors.map(\.name) == ["Device motion", "Magnetometer"])
    #expect(store.captures[0].sensors[0].value == "0.02 g")
    #expect(feed.widgets[0].value == "0.02 g")
    #expect(controller.captures[0].id == store.captures[0].id)
}

@MainActor
@Test func aDetectionBeepsAndSavesTheQuantifiedWindow() {
    let feed = SensorFeed(widgets: [
        SensorWidgetState(kind: .magnetometer, status: .live, value: "68.4 µT"),
    ])
    let captures = MemoryCaptureStore()
    let detections = MemoryDetectionStore()
    let alert = CountingDetectionAlert()
    let controller = DashboardController(
        feed: feed,
        store: captures,
        detections: detections,
        alert: alert
    )
    controller.placeName = "Hallway"
    let hit = LeadHit(
        id: UUID(),
        kind: .magneticDisturbance,
        feature: "Field magnitude",
        magnitude: 16.4,
        threshold: DetectionLimit.fieldMagnitude,
        timestamp: 12,
        samples: [53.8, 54.1, 68.4]
    )
    controller.record([hit])
    controller.record([])

    #expect(alert.announcements == 1)
    #expect(detections.detections.count == 1)
    #expect(detections.detections[0].placeName == "Hallway")
    #expect(detections.detections[0].magnitudeLabel == "16.4 µT")
    #expect(detections.detections[0].thresholdLabel == "12 µT")
    #expect(detections.detections[0].samples == [53.8, 54.1, 68.4])
    #expect(detections.detections[0].elapsed == "0:12.0")
    #expect(detections.detections[0].sensors[0].value == "68.4 µT")
    #expect(controller.announced?.id == hit.id)
    #expect(controller.captures.isEmpty)
}

@Test func fileStoreRoundTripsADetection() throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).json")
    let store = FileDetectionStore(fileURL: url)
    let detection = SavedDetection(
        id: UUID(),
        placeName: "Hallway",
        savedAt: Date(timeIntervalSince1970: 1_700_000_000),
        elapsed: "0:12.4",
        kind: "magneticDisturbance",
        title: "Magnetic disturbance",
        feature: "Field magnitude",
        magnitude: 16.4,
        magnitudeLabel: "16.4 µT",
        threshold: 12,
        thresholdLabel: "12 µT",
        samples: [53.8, 68.4],
        sampleLabel: "53.8 · 68.4",
        sensors: [
            SavedSensor(kind: "magnetometer", name: "Magnetometer", status: "Live", value: "68.4 µT"),
        ]
    )
    store.save([detection])
    #expect(store.load() == [detection])
}

@MainActor
final class CountingDetectionAlert: DetectionAlerting {
    var announcements = 0

    func announce() {
        announcements += 1
    }
}

@Test func fileStoreRoundTripsACapture() throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).json")
    let store = FileCaptureStore(fileURL: url)
    let capture = SavedCapture(
        id: UUID(),
        placeName: "Hallway",
        savedAt: Date(timeIntervalSince1970: 1_700_000_000),
        elapsed: "0:12.4",
        sensors: [
            SavedSensor(kind: "deviceMotion", name: "Device motion", status: "Live", value: "0.02 g"),
        ]
    )
    store.save([capture])
    #expect(store.load() == [capture])
}
