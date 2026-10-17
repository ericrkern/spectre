import Foundation

struct HeadingFrame: Equatable, Sendable {
    var timestamp: TimeInterval
    var magneticHeading: Double
    var accuracy: Double
}

struct CameraMeter: Equatable, Sendable {
    var luma: Double
    var exposureSeconds: Double?
    var iso: Double?
    var aperture: Double?
}

struct BrightnessFrame: Equatable, Sendable {
    var timestamp: TimeInterval
    var meter: CameraMeter
}

enum MeterFormat {
    static func caption(_ meter: CameraMeter) -> String {
        var parts: [String] = []
        if let exposure = meter.exposureSeconds, let label = exposureLabel(exposure) {
            parts.append(label)
        }
        if let iso = meter.iso, iso > 0 {
            parts.append("ISO \(Int(iso.rounded()))")
        }
        if let aperture = meter.aperture, aperture > 0 {
            parts.append(String(format: "f/%.1f", aperture))
        }
        return parts.joined(separator: " · ")
    }

    static func exposureLabel(_ seconds: Double) -> String? {
        guard seconds.isFinite, seconds > 0 else { return nil }
        if seconds >= 0.1 {
            return String(format: "%.2f s", seconds)
        }
        let denominator = max(1, Int((1 / seconds).rounded()))
        return "1/\(denominator) s"
    }
}

/// Flags compass instability only while the phone is still.
/// A turn clears the lock, so rotating the phone is not a hit.
struct HeadingDetector: Equatable {
    var sensitivity = DetectionSensitivity.standard
    private(set) var phase: HeadingPhase = .idle
    private var lockedHeading: Double?
    private var lockedAccuracy: Double?
    private var recentHeading: [Double] = []
    private var recentAccuracy: [Double] = []
    private var cooldownUntil: [String: TimeInterval] = [:]

    static let movingText = "Heading waits until the phone is still."
    static let watchingText = "Watching heading while the phone is still."

    var statusText: String {
        switch phase {
        case .idle: ""
        case .moving: Self.movingText
        case .locked: Self.watchingText
        }
    }

    mutating func noteInterruption() {
        phase = .idle
        lockedHeading = nil
        lockedAccuracy = nil
        recentHeading = []
        recentAccuracy = []
        cooldownUntil = [:]
    }

    mutating func ingest(_ frame: HeadingFrame, phoneIsStill: Bool) -> [LeadHit] {
        guard frame.accuracy >= 0, frame.magneticHeading >= 0 else { return [] }
        guard phoneIsStill else {
            phase = .moving
            lockedHeading = nil
            lockedAccuracy = nil
            recentHeading = []
            recentAccuracy = []
            return []
        }
        phase = .locked
        guard let lockedHeading, let lockedAccuracy else {
            self.lockedHeading = frame.magneticHeading
            self.lockedAccuracy = frame.accuracy
            recentHeading = [frame.magneticHeading]
            recentAccuracy = [frame.accuracy]
            return []
        }
        recentHeading = remember(frame.magneticHeading, in: recentHeading)
        recentAccuracy = remember(frame.accuracy, in: recentAccuracy)
        var hits: [LeadHit] = []
        let yaw = circularDelta(frame.magneticHeading, lockedHeading)
        let yawLimit = sensitivity.scaled(DetectionLimit.headingYaw)
        if yaw >= yawLimit {
            hits.append(contentsOf: emit(
                feature: "Yaw wander",
                magnitude: yaw,
                threshold: yawLimit,
                timestamp: frame.timestamp,
                detail: nil,
                samples: recentHeading
            ))
        }
        let worsening = frame.accuracy - lockedAccuracy
        let accuracyLimit = sensitivity.scaled(DetectionLimit.headingAccuracyRise)
        if worsening >= accuracyLimit, frame.accuracy >= 25 {
            hits.append(contentsOf: emit(
                feature: "Heading accuracy",
                magnitude: worsening,
                threshold: accuracyLimit,
                timestamp: frame.timestamp,
                detail: "\(Int(frame.accuracy.rounded()))°",
                samples: recentAccuracy
            ))
        }
        return hits
    }

    private mutating func emit(
        feature: String,
        magnitude: Double,
        threshold: Double,
        timestamp: TimeInterval,
        detail: String?,
        samples: [Double]
    ) -> [LeadHit] {
        if let until = cooldownUntil[feature], timestamp < until {
            return []
        }
        cooldownUntil[feature] = timestamp + 6
        return [
            LeadHit(
                id: UUID(),
                kind: .heading,
                feature: feature,
                magnitude: magnitude,
                threshold: threshold,
                timestamp: timestamp,
                samples: samples,
                detail: detail
            ),
        ]
    }

    private func remember(_ value: Double, in buffer: [Double]) -> [Double] {
        var buffer = buffer
        buffer.append(value)
        if buffer.count > 20 {
            buffer.removeFirst()
        }
        return buffer
    }

    private func circularDelta(_ a: Double, _ b: Double) -> Double {
        let raw = abs(a - b).truncatingRemainder(dividingBy: 360)
        return min(raw, 360 - raw)
    }
}

enum HeadingPhase: Equatable, Sendable {
    case idle
    case moving
    case locked
}

/// Learns the camera's meter, then flags a luma, exposure, ISO, or aperture shift.
struct BrightnessDetector: Equatable {
    var sensitivity = DetectionSensitivity.standard
    private(set) var phase: SoundPhase = .waiting
    private var lumaHistory: [Double] = []
    private var exposureHistory: [Double] = []
    private var isoHistory: [Double] = []
    private var apertureHistory: [Double] = []
    private var baselineLuma = 0.0
    private var baselineExposure: Double?
    private var baselineISO: Double?
    private var baselineAperture: Double?
    private var recentLuma: [Double] = []
    private var cooldownUntil: [String: TimeInterval] = [:]

    static let learningText = "Learning the room's light."
    static let watchingText = "Watching for a brightness shift."

    var statusText: String {
        switch phase {
        case .waiting: ""
        case .learning: Self.learningText
        case .watching: Self.watchingText
        }
    }

    mutating func noteInterruption() {
        phase = .waiting
        lumaHistory = []
        exposureHistory = []
        isoHistory = []
        apertureHistory = []
        recentLuma = []
        cooldownUntil = [:]
    }

    mutating func ingest(_ frame: BrightnessFrame) -> [LeadHit] {
        let meter = frame.meter
        switch phase {
        case .waiting:
            phase = .learning(startedAt: frame.timestamp)
            rememberBaseline(meter)
            return []
        case .learning(let startedAt):
            rememberBaseline(meter)
            if frame.timestamp - startedAt >= DetectionLimit.brightnessBaseline {
                finishBaseline()
                phase = .watching
            }
            return []
        case .watching:
            recentLuma = remember(meter.luma, in: recentLuma)
            return detect(frame)
        }
    }

    private mutating func rememberBaseline(_ meter: CameraMeter) {
        lumaHistory.append(meter.luma)
        if let exposure = meter.exposureSeconds, exposure > 0 {
            exposureHistory.append(exposure)
        }
        if let iso = meter.iso, iso > 0 {
            isoHistory.append(iso)
        }
        if let aperture = meter.aperture, aperture > 0 {
            apertureHistory.append(aperture)
        }
    }

    private mutating func finishBaseline() {
        baselineLuma = SignalMeasure.median(lumaHistory)
        baselineExposure = exposureHistory.isEmpty ? nil : SignalMeasure.median(exposureHistory)
        baselineISO = isoHistory.isEmpty ? nil : SignalMeasure.median(isoHistory)
        baselineAperture = apertureHistory.isEmpty ? nil : SignalMeasure.median(apertureHistory)
    }

    private mutating func detect(_ frame: BrightnessFrame) -> [LeadHit] {
        let meter = frame.meter
        var hits: [LeadHit] = []
        let lumaDelta = meter.luma - baselineLuma
        let lumaLimit = sensitivity.scaled(DetectionLimit.lumaShift)
        if abs(lumaDelta) >= lumaLimit {
            hits.append(contentsOf: emit(
                feature: "Luma",
                magnitude: lumaDelta,
                threshold: lumaLimit,
                timestamp: frame.timestamp,
                detail: nil,
                samples: recentLuma
            ))
        }
        let exposureLimit = sensitivity.scaledRatio(DetectionLimit.exposureRatio)
        if let baselineExposure, let change = ratio(meter.exposureSeconds, over: baselineExposure, limit: exposureLimit) {
            hits.append(contentsOf: emit(
                feature: "Exposure",
                magnitude: change,
                threshold: exposureLimit,
                timestamp: frame.timestamp,
                detail: meter.exposureSeconds.flatMap(MeterFormat.exposureLabel),
                samples: recentLuma
            ))
        }
        let isoLimit = sensitivity.scaledRatio(DetectionLimit.isoRatio)
        if let baselineISO, let change = ratio(meter.iso, over: baselineISO, limit: isoLimit) {
            hits.append(contentsOf: emit(
                feature: "ISO",
                magnitude: change,
                threshold: isoLimit,
                timestamp: frame.timestamp,
                detail: meter.iso.map { "ISO \(Int($0.rounded()))" },
                samples: recentLuma
            ))
        }
        let apertureLimit = sensitivity.scaledRatio(DetectionLimit.apertureRatio)
        if let baselineAperture, let change = ratio(meter.aperture, over: baselineAperture, limit: apertureLimit) {
            hits.append(contentsOf: emit(
                feature: "Aperture",
                magnitude: change,
                threshold: apertureLimit,
                timestamp: frame.timestamp,
                detail: meter.aperture.map { String(format: "f/%.1f", $0) },
                samples: recentLuma
            ))
        }
        return hits
    }

    private func ratio(_ current: Double?, over baseline: Double, limit: Double) -> Double? {
        guard let current, current > 0, baseline > 0 else { return nil }
        let change = max(current / baseline, baseline / current)
        return change >= limit ? change : nil
    }

    private mutating func emit(
        feature: String,
        magnitude: Double,
        threshold: Double,
        timestamp: TimeInterval,
        detail: String?,
        samples: [Double]
    ) -> [LeadHit] {
        if let until = cooldownUntil[feature], timestamp < until {
            return []
        }
        cooldownUntil[feature] = timestamp + 6
        return [
            LeadHit(
                id: UUID(),
                kind: .brightness,
                feature: feature,
                magnitude: magnitude,
                threshold: threshold,
                timestamp: timestamp,
                samples: samples,
                detail: detail
            ),
        ]
    }

    private func remember(_ value: Double, in buffer: [Double]) -> [Double] {
        var buffer = buffer
        buffer.append(value)
        if buffer.count > 20 {
            buffer.removeFirst()
        }
        return buffer
    }
}

struct LeadGroup: Identifiable, Equatable {
    var detections: [SavedDetection]

    var id: UUID { detections[0].id }

    var sameMoment: Bool {
        detections.count > 1 && Set(detections.map(\.kind)).count > 1
    }
}

enum LeadTimeline {
    /// Groups hits whose times fall within two seconds, without merging them.
    static func groups(_ detections: [SavedDetection]) -> [LeadGroup] {
        let timed = detections
            .filter { $0.elapsedSeconds != nil }
            .sorted { ($0.elapsedSeconds ?? 0) > ($1.elapsedSeconds ?? 0) }
        let untimed = detections.filter { $0.elapsedSeconds == nil }
        var groups: [LeadGroup] = []
        for detection in timed {
            if let index = groups.indices.last,
               let newest = groups[index].detections.first?.elapsedSeconds,
               let time = detection.elapsedSeconds,
               abs(newest - time) <= 2 {
                groups[index].detections.append(detection)
            } else {
                groups.append(LeadGroup(detections: [detection]))
            }
        }
        groups.append(contentsOf: untimed.map { LeadGroup(detections: [$0]) })
        return groups
    }
}
