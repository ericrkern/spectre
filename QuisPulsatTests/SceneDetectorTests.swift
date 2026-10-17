import Foundation
import Testing
@testable import QuisPulsat

private func heading(_ degrees: Double, accuracy: Double, at timestamp: TimeInterval) -> HeadingFrame {
    HeadingFrame(timestamp: timestamp, magneticHeading: degrees, accuracy: accuracy)
}

private func light(
    luma: Double,
    exposure: Double? = 1.0 / 60,
    iso: Double? = 200,
    aperture: Double? = 1.6,
    at timestamp: TimeInterval
) -> BrightnessFrame {
    BrightnessFrame(
        timestamp: timestamp,
        meter: CameraMeter(luma: luma, exposureSeconds: exposure, iso: iso, aperture: aperture)
    )
}

private func learnLight(_ detector: inout BrightnessDetector, luma: Double = 40) {
    var timestamp = 0.0
    while timestamp < DetectionLimit.brightnessBaseline {
        _ = detector.ingest(light(luma: luma, at: timestamp))
        timestamp += 0.5
    }
    _ = detector.ingest(light(luma: luma, at: DetectionLimit.brightnessBaseline))
}

@Test func turningThePhoneIsNotAHeadingHit() {
    var detector = HeadingDetector()
    #expect(detector.ingest(heading(10, accuracy: 5, at: 1), phoneIsStill: false).isEmpty)
    #expect(detector.ingest(heading(200, accuracy: 40, at: 2), phoneIsStill: false).isEmpty)
    #expect(detector.phase == .moving)
}

@Test func aMagnetPullsHeadingOnlyWhileThePhoneIsStill() {
    var detector = HeadingDetector()
    #expect(detector.ingest(heading(90, accuracy: 8, at: 1), phoneIsStill: true).isEmpty)
    let hits = detector.ingest(heading(120, accuracy: 8, at: 2), phoneIsStill: true)
    #expect(hits.map(\.feature) == ["Yaw wander"])
    #expect(hits[0].kind == .heading)
    #expect(hits[0].magnitude >= DetectionLimit.headingYaw)
    #expect(hits[0].samples.isEmpty == false)
}

@Test func headingAcrossNorthIsTheShortTurn() {
    var detector = HeadingDetector()
    _ = detector.ingest(heading(350, accuracy: 8, at: 1), phoneIsStill: true)
    let hits = detector.ingest(heading(10, accuracy: 8, at: 2), phoneIsStill: true)
    #expect(hits.map(\.feature) == ["Yaw wander"])
    #expect(abs(hits[0].magnitude - 20) < 0.01)
}

@Test func aSmallDriftWhileStillIsNotAHeadingHit() {
    var detector = HeadingDetector()
    _ = detector.ingest(heading(90, accuracy: 8, at: 1), phoneIsStill: true)
    #expect(detector.ingest(heading(95, accuracy: 12, at: 2), phoneIsStill: true).isEmpty)
}

@Test func headingAccuracyWorsensWhileThePhoneIsStill() {
    var detector = HeadingDetector()
    _ = detector.ingest(heading(90, accuracy: 8, at: 1), phoneIsStill: true)
    let hits = detector.ingest(heading(92, accuracy: 40, at: 2), phoneIsStill: true)
    #expect(hits.map(\.feature) == ["Heading accuracy"])
    #expect(hits[0].detail == "40°")
}

@Test func movingClearsTheHeadingLock() {
    var detector = HeadingDetector()
    _ = detector.ingest(heading(10, accuracy: 8, at: 1), phoneIsStill: true)
    #expect(detector.ingest(heading(80, accuracy: 8, at: 2), phoneIsStill: false).isEmpty)
    #expect(detector.ingest(heading(84, accuracy: 8, at: 3), phoneIsStill: true).isEmpty)
}

@Test func aLampChangesLumaAndTheSameLightDoesNot() {
    var detector = BrightnessDetector()
    learnLight(&detector)
    #expect(detector.phase == .watching)
    var steady: [LeadHit] = []
    var timestamp = 5.5
    while timestamp < 8 {
        steady.append(contentsOf: detector.ingest(light(luma: 40, at: timestamp)))
        timestamp += 0.5
    }
    #expect(steady.isEmpty)
    let hits = detector.ingest(light(luma: 110, at: 9))
    #expect(hits.map(\.feature) == ["Luma"])
    #expect(hits[0].kind == .brightness)
    #expect(hits[0].magnitude == 70)
    #expect(hits[0].threshold == DetectionLimit.lumaShift)
}

@Test func exposureIsoAndApertureEachStayTheirOwnHit() {
    var exposureDetector = BrightnessDetector()
    learnLight(&exposureDetector)
    let exposure = exposureDetector.ingest(light(luma: 40, exposure: 1.0 / 480, at: 6))
    #expect(exposure.map(\.feature) == ["Exposure"])
    #expect(exposure[0].detail == "1/480 s")

    var isoDetector = BrightnessDetector()
    learnLight(&isoDetector)
    let iso = isoDetector.ingest(light(luma: 40, iso: 800, at: 6))
    #expect(iso.map(\.feature) == ["ISO"])
    #expect(iso[0].detail == "ISO 800")

    var apertureDetector = BrightnessDetector()
    learnLight(&apertureDetector)
    let aperture = apertureDetector.ingest(light(luma: 40, aperture: 2.4, at: 6))
    #expect(aperture.map(\.feature) == ["Aperture"])
    #expect(aperture[0].detail == "f/2.4")
}

@Test func theCameraMeterCaptionShowsExposureIsoAndAperture() {
    let caption = MeterFormat.caption(CameraMeter(luma: 40, exposureSeconds: 1.0 / 60, iso: 200, aperture: 1.6))
    #expect(caption == "1/60 s · ISO 200 · f/1.6")
}

@Test func aHeadingHitBesideAMagneticHitStaysTwoRows() {
    let headingHit = saved(kind: "heading", title: "Heading instability", seconds: 12)
    let magneticHit = saved(kind: "magneticDisturbance", title: "Magnetic disturbance", seconds: 11.4)
    let earlier = saved(kind: "sound", title: "Sound", seconds: 3)
    let groups = LeadTimeline.groups([magneticHit, earlier, headingHit])
    #expect(groups.count == 2)
    #expect(groups[0].sameMoment)
    #expect(groups[0].detections.map(\.kind) == ["heading", "magneticDisturbance"])
    #expect(groups[1].detections.map(\.kind) == ["sound"])
    #expect(groups[0].detections[0].id != groups[0].detections[1].id)
}

private func saved(kind: String, title: String, seconds: Double) -> SavedDetection {
    SavedDetection(
        id: UUID(),
        placeName: "Hallway",
        savedAt: Date(timeIntervalSince1970: 1_700_000_000),
        elapsed: "0:12.0",
        kind: kind,
        title: title,
        feature: "Feature",
        magnitude: 1,
        magnitudeLabel: "1",
        threshold: 1,
        thresholdLabel: "1",
        samples: [1],
        sampleLabel: "1",
        sensors: [],
        elapsedSeconds: seconds
    )
}
