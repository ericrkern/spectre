import Foundation
import Testing
@testable import Spectre

private let earth = Vector3(x: 20, y: 30, z: 40)

private func frame(
    _ timestamp: TimeInterval,
    field: Vector3 = earth,
    accuracy: FieldAccuracy = .high,
    raw: Vector3? = earth,
    acceleration: Double = 0.01,
    rotation: Double = 0.01
) -> DeviceMotionFrame {
    DeviceMotionFrame(
        timestamp: timestamp,
        userAcceleration: Vector3(x: acceleration, y: 0, z: 0),
        rotationRate: Vector3(x: rotation, y: 0, z: 0),
        calibratedField: field,
        fieldAccuracy: accuracy,
        rawField: raw
    )
}

private func watch() -> InvestigationDetectors {
    var detectors = InvestigationDetectors()
    _ = detectors.ingest(motion: frame(0))
    _ = detectors.ingest(motion: frame(0.8))
    #expect(detectors.phase == .learning(startedAt: 0.8))
    for timestamp in stride(from: 1.0, through: 5.6, by: 0.4) {
        _ = detectors.ingest(motion: frame(timestamp))
        _ = detectors.ingest(pressure: PressureFrame(timestamp: timestamp, kilopascals: 101.30))
    }
    _ = detectors.ingest(motion: frame(5.8))
    _ = detectors.ingest(pressure: PressureFrame(timestamp: 5.8, kilopascals: 101.30))
    #expect(detectors.phase == .watching)
    return detectors
}

@Test func thePhoneIsStillOnlyAfterItHasRested() {
    let detectors = watch()
    #expect(detectors.phoneIsStill(at: 5.8) == false)
    #expect(detectors.phoneIsStill(at: 7) == true)
}

@Test func aStillPhoneLearnsTheRoomBeforeItWatches() {
    var detectors = InvestigationDetectors()
    _ = detectors.ingest(motion: frame(0, acceleration: 0.4))
    #expect(detectors.phase == .waitingForStillness)
    let armed = watch()
    #expect(armed.phase == .watching)
    #expect(armed.statusText == InvestigationDetectors.watchingText)
}

@Test func magneticMagnitudeAndVectorJumpStaySeparateLeads() {
    var detectors = watch()
    let scale = (earth.magnitude + 15) / earth.magnitude
    let stronger = Vector3(x: earth.x * scale, y: earth.y * scale, z: earth.z * scale)
    let magnitudeHits = detectors.ingest(motion: frame(6.2, field: stronger))
    #expect(magnitudeHits[0].threshold == DetectionLimit.fieldMagnitude)
    #expect(magnitudeHits.map(\.feature) == ["Field magnitude"])
    #expect(magnitudeHits[0].kind == .magneticDisturbance)
    #expect(magnitudeHits[0].samples.isEmpty == false)
    let cooled = detectors.ingest(motion: frame(7.0, field: stronger))
    #expect(cooled.isEmpty)

    let turned = Vector3(x: 40, y: 20, z: 30)
    let vectorHits = detectors.ingest(motion: frame(13, field: turned))
    #expect(vectorHits.map(\.feature) == ["Vector jump"])
    #expect(vectorHits[0].kind == .magneticDisturbance)
}

@Test func accuracyDropAndRawFieldAreTheirOwnLeads() {
    var detectors = watch()
    let raw = Vector3(x: 80, y: 0, z: 0)
    let hits = detectors.ingest(motion: frame(6.2, accuracy: .unreliable, raw: raw))
    let features = Set(hits.map(\.feature))
    #expect(features.contains("Field accuracy"))
    #expect(features.contains("Raw field"))
    #expect(hits.allSatisfy { $0.kind == .magneticDisturbance })
    #expect(hits.count == features.count)
}

@Test func aPressureStepIsNotTheSlowDrift() {
    var detectors = watch()
    var driftHits: [LeadHit] = []
    for index in 0..<40 {
        let pressure = 101.30 + Double(index) * 0.00015
        driftHits.append(contentsOf: detectors.ingest(pressure: PressureFrame(timestamp: 6 + Double(index), kilopascals: pressure)))
    }
    #expect(driftHits.isEmpty)

    let step = detectors.ingest(pressure: PressureFrame(timestamp: 50, kilopascals: 101.36))
    #expect(step.map(\.kind) == [.pressureChange])
    #expect(step[0].feature == "Pressure step")
    #expect(step[0].magnitude > 0)
}

@Test func aBumpWhileStillIsALeadAndWalkingIsNot() {
    var detectors = watch()
    _ = detectors.ingest(motion: frame(6.4))
    _ = detectors.ingest(motion: frame(7.0))
    let bump = detectors.ingest(motion: frame(7.1, acceleration: 0.42))
    #expect(bump.map(\.feature) == ["User acceleration"])
    #expect(bump[0].kind == .unattendedMotion)

    var walking = watch()
    _ = walking.ingest(motion: frame(6.4))
    _ = walking.ingest(motion: frame(7.0))
    walking.noteSteps(0, at: 7.0)
    walking.noteSteps(3, at: 7.05)
    let ignored = walking.ingest(motion: frame(7.1, acceleration: 0.42))
    #expect(ignored.isEmpty)
}

@Test func rotationWhileStillIsSeparateFromAcceleration() {
    var detectors = watch()
    _ = detectors.ingest(motion: frame(6.4))
    _ = detectors.ingest(motion: frame(7.0))
    let hits = detectors.ingest(motion: frame(7.1, rotation: 1.6))
    #expect(hits.map(\.feature) == ["Rotation"])
}

@Test func magneticAndPressureHitsAtTheSameTimeStayTwoLeads() {
    var detectors = watch()
    let scale = (earth.magnitude + 15) / earth.magnitude
    let stronger = Vector3(x: earth.x * scale, y: earth.y * scale, z: earth.z * scale)
    let magnetic = detectors.ingest(motion: frame(6.2, field: stronger))
    let pressure = detectors.ingest(pressure: PressureFrame(timestamp: 6.2, kilopascals: 101.36))
    #expect(magnetic.count == 1)
    #expect(pressure.count == 1)
    #expect(magnetic[0].kind != pressure[0].kind)
    #expect(magnetic[0].id != pressure[0].id)
}

@Test func standardSensitivityKeepsTheDesignedThreshold() {
    #expect(DetectionSensitivity.standard.factor == 1)
    #expect(DetectionSensitivity.standard.scaled(DetectionLimit.fieldMagnitude) == 12)
    #expect(DetectionSensitivity.standard.label == "Standard")
}

@Test func theSensitivityDialReadsTheTopAsStandard() {
    let top = SensitivityDialMath.fraction(dx: 0, dy: -1)
    #expect(abs(top - 0.5) < 0.02)
    let start = cos(135 * Double.pi / 180)
    let startY = sin(135 * Double.pi / 180)
    #expect(SensitivityDialMath.fraction(dx: start, dy: startY) < 0.02)
}

@Test func aKeenerDialFlagsASmallerMagneticChange() {
    var detectors = watch()
    let magnitude = earth.magnitude
    let scale = (magnitude + 8) / magnitude
    let stronger = Vector3(x: earth.x * scale, y: earth.y * scale, z: earth.z * scale)
    #expect(detectors.ingest(motion: frame(6.2, field: stronger)).isEmpty)
    detectors.sensitivity = DetectionSensitivity(level: 1)
    let hits = detectors.ingest(motion: frame(6.4, field: stronger))
    #expect(hits.map(\.feature) == ["Field magnitude"])
    #expect(abs(hits[0].threshold - 6) < 0.001)
}

@Test func aGuardedDialIgnoresAChangeTheStandardDialWouldKeep() {
    var detectors = watch()
    detectors.sensitivity = DetectionSensitivity(level: 0)
    let magnitude = earth.magnitude
    let scale = (magnitude + 15) / magnitude
    let stronger = Vector3(x: earth.x * scale, y: earth.y * scale, z: earth.z * scale)
    #expect(detectors.ingest(motion: frame(6.2, field: stronger)).isEmpty)
}

@Test func movingDuringLearningStartsTheBaselineOver() {
    var detectors = InvestigationDetectors()
    _ = detectors.ingest(motion: frame(0))
    _ = detectors.ingest(motion: frame(0.8))
    let hits = detectors.ingest(motion: frame(2, acceleration: 0.5))
    #expect(hits.isEmpty)
    #expect(detectors.phase == .waitingForStillness)
}
