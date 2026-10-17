import Foundation

struct Vector3: Equatable, Sendable {
    var x: Double
    var y: Double
    var z: Double

    var magnitude: Double {
        (x * x + y * y + z * z).squareRoot()
    }

    func distance(to other: Vector3) -> Double {
        let dx = x - other.x
        let dy = y - other.y
        let dz = z - other.z
        return (dx * dx + dy * dy + dz * dz).squareRoot()
    }

    static let zero = Vector3(x: 0, y: 0, z: 0)
}

enum FieldAccuracy: Int, Equatable, Sendable {
    case unknown = 0
    case unreliable = 1
    case low = 2
    case medium = 3
    case high = 4
}

struct DeviceMotionFrame: Equatable, Sendable {
    var timestamp: TimeInterval
    var userAcceleration: Vector3
    var rotationRate: Vector3
    /// Calibrated magnetic field in the reference frame, so turning the phone is not a vector jump.
    var calibratedField: Vector3
    var fieldAccuracy: FieldAccuracy
    /// Unfused magnetometer vector, in the device frame.
    var rawField: Vector3?
}

struct PressureFrame: Equatable, Sendable {
    var timestamp: TimeInterval
    var kilopascals: Double
}

enum LeadKind: String, Equatable, Sendable {
    case magneticDisturbance
    case pressureChange
    case unattendedMotion
    case sound
    case heading
    case brightness
    case depth
    case radio

    var title: String {
        switch self {
        case .magneticDisturbance: "Magnetic disturbance"
        case .pressureChange: "Pressure change"
        case .unattendedMotion: "Unattended motion"
        case .sound: "Sound"
        case .heading: "Heading instability"
        case .brightness: "Brightness shift"
        case .depth: "Empty-space depth"
        case .radio: "Radio presence"
        }
    }
}

enum DetectionLimit {
    static let fieldMagnitude = 12.0
    static let vectorJump = 18.0
    static let rawField = 12.0
    static let pressureStep = 0.02
    static let userAcceleration = 0.25
    static let rotation = 1.2
    static let accuracyFloor = Double(FieldAccuracy.low.rawValue)
    static let soundBaseline = 5.0
    static let soundPeakRise = 10.0
    static let soundToneRise = 8.0
    static let soundToneHold = 0.40
    static let soundToneShare = 0.35
    static let headingYaw = 18.0
    static let headingAccuracyRise = 20.0
    static let brightnessBaseline = 5.0
    static let lumaShift = 40.0
    static let exposureRatio = 2.0
    static let isoRatio = 2.0
    static let apertureRatio = 1.4
    static let depthBaseline = 5.0
    static let depthClosure = 0.40
    static let depthConfidence = 1
    static let radioBaseline = 5.0
    static let rssiJump = 12.0

    static let summary = "Magnetic 12 µT · Vector 18 µT · Pressure 0.02 kPa · Motion 0.25 g or 1.2 rad/s · Sound peak +10 dB or a tone held 0.4 s · Heading 18° while still · Luma ±40 · Depth 0.40 m into empty space · RSSI ±12 dBm or a new advertisement"
}

/// Scales numeric detection limits. The middle of the dial keeps the designed thresholds.
/// Toward the high end, a smaller change counts as a hit.
struct DetectionSensitivity: Equatable, Sendable {
    var level: Double

    static let standard = DetectionSensitivity(level: 0.5)

    var factor: Double {
        let clamped = min(max(level, 0), 1)
        if clamped <= 0.5 {
            return 2 - 2 * clamped
        }
        return 1.5 - clamped
    }

    func scaled(_ base: Double) -> Double {
        base * factor
    }

    func scaledRatio(_ base: Double) -> Double {
        max(1.15, base * factor)
    }

    func scaledShare(_ base: Double) -> Double {
        min(0.9, max(0.12, base * factor))
    }

    var label: String {
        switch level {
        case ..<0.2: "Guarded"
        case ..<0.4: "Low"
        case ..<0.6: "Standard"
        case ..<0.8: "High"
        default: "Keen"
        }
    }

    /// Guarded is 1 ft. Keen is 100 ft. The middle of the dial is halfway between them.
    var nearbyFeet: Double {
        let clamped = min(max(level, 0), 1)
        return NearbyScan.minFeet + clamped * (NearbyScan.maxFeet - NearbyScan.minFeet)
    }

    var summary: String {
        String(
            format: "Magnetic %.0f µT · Vector %.0f µT · Pressure %.2f kPa · Motion %.2f g or %.1f rad/s · Sound peak +%.0f dB · Heading %.0f° · Luma ±%.0f · Depth %.2f m · RSSI ±%.0f dBm",
            scaled(DetectionLimit.fieldMagnitude),
            scaled(DetectionLimit.vectorJump),
            scaled(DetectionLimit.pressureStep),
            scaled(DetectionLimit.userAcceleration),
            scaled(DetectionLimit.rotation),
            scaled(DetectionLimit.soundPeakRise),
            scaled(DetectionLimit.headingYaw),
            scaled(DetectionLimit.lumaShift),
            scaled(DetectionLimit.depthClosure),
            scaled(DetectionLimit.rssiJump)
        )
    }
}

struct LeadHit: Identifiable, Equatable, Sendable {
    var id: UUID
    var kind: LeadKind
    var feature: String
    var magnitude: Double
    var threshold: Double
    var timestamp: TimeInterval
    var samples: [Double]
    var detail: String? = nil
    var clipWAV: Data? = nil

    var magnitudeLabel: String {
        switch feature {
        case "Field magnitude", "Vector jump", "Raw field":
            String(format: "%.1f µT", magnitude)
        case "Field accuracy":
            "Accuracy dropped"
        case "Pressure step":
            String(format: "%+.2f kPa", magnitude)
        case "User acceleration":
            String(format: "%.2f g", magnitude)
        case "Rotation":
            String(format: "%.2f rad/s", magnitude)
        case "Level peak":
            String(format: "%.0f dB", magnitude)
        case "Narrow tone":
            if let detail {
                "\(Int(magnitude.rounded())) dB · \(detail)"
            } else {
                String(format: "%.0f dB", magnitude)
            }
        case "Yaw wander":
            String(format: "%.0f°", magnitude)
        case "Heading accuracy":
            String(format: "+%.0f°", magnitude)
        case "Luma":
            String(format: "%+.0f luma", magnitude)
        case "Exposure", "ISO", "Aperture":
            if let detail {
                String(format: "%.1f× · %@", magnitude, detail)
            } else {
                String(format: "%.1f×", magnitude)
            }
        case "Empty space":
            String(format: "%.2f m closer", magnitude)
        case "New advertisement":
            String(format: "%.0f dBm", magnitude)
        case "RSSI change":
            String(format: "%+.0f dBm", magnitude)
        default:
            String(format: "%.2f", magnitude)
        }
    }

    var thresholdLabel: String {
        switch feature {
        case "Field magnitude", "Vector jump", "Raw field":
            String(format: "%.0f µT", threshold)
        case "Field accuracy":
            "Low"
        case "Pressure step":
            String(format: "%.2f kPa", threshold)
        case "User acceleration":
            String(format: "%.2f g", threshold)
        case "Rotation":
            String(format: "%.1f rad/s", threshold)
        case "Level peak", "Narrow tone":
            String(format: "%.0f dB", threshold)
        case "Yaw wander", "Heading accuracy":
            String(format: "%.0f°", threshold)
        case "Luma":
            String(format: "%.0f luma", threshold)
        case "Exposure", "ISO", "Aperture":
            String(format: "%.1f×", threshold)
        case "Empty space":
            String(format: "%.2f m", threshold)
        case "New advertisement":
            "New"
        case "RSSI change":
            String(format: "%.0f dBm", threshold)
        default:
            String(format: "%.2f", threshold)
        }
    }

    var sampleLabel: String {
        samples.map { value in
            switch feature {
            case "Field magnitude", "Vector jump", "Raw field":
                String(format: "%.1f", value)
            case "Level peak", "Narrow tone":
                String(format: "%.0f", value)
            case "Yaw wander", "Heading accuracy", "Luma", "Exposure", "ISO", "Aperture":
                String(format: "%.0f", value)
            default:
                String(format: "%.2f", value)
            }
        }.joined(separator: " · ")
    }
}

enum WatchPhase: Equatable, Sendable {
    case waitingForStillness
    case learning(startedAt: TimeInterval)
    case watching
}

/// Learns a still room, then emits independent leads.
/// Magnetic, pressure, and unattended-motion hits are never merged.
struct InvestigationDetectors: Equatable {
    var sensitivity = DetectionSensitivity.standard
    private(set) var phase: WatchPhase = .waitingForStillness
    private var stillSince: TimeInterval?
    private var lastStepCount: Int?
    private var lastStepChange: TimeInterval?
    private var learningMotion: [DeviceMotionFrame] = []
    private var learningPressure: [Double] = []
    private var learningRaw: [Double] = []

    private var baselineMagnitude = 0.0
    private var baselineVector = Vector3.zero
    private var baselineAccuracy: FieldAccuracy = .unknown
    private var baselineRawMagnitude: Double?
    private var magneticReady = false

    private var slowPressure: Double?
    private var recentPressure: [Double] = []
    private var pressureArmed = true

    private var recentAcceleration: [Double] = []
    private var recentRotation: [Double] = []
    private var recentFieldMagnitude: [Double] = []
    private var recentVectorDistance: [Double] = []
    private var recentRawMagnitude: [Double] = []

    private var cooldownUntil: [String: TimeInterval] = [:]

    static let waitingText = "Set the phone down. Spectre learns the room once it is still."
    static let learningText = "Learning the room."
    static let watchingText = "Watching for magnetic, pressure, and motion leads."

    var statusText: String {
        switch phase {
        case .waitingForStillness: Self.waitingText
        case .learning: Self.learningText
        case .watching: Self.watchingText
        }
    }

    mutating func noteSteps(_ steps: Int, at timestamp: TimeInterval) {
        if let lastStepCount, steps > lastStepCount {
            lastStepChange = timestamp
        }
        lastStepCount = steps
    }

    mutating func noteInterruption() {
        stillSince = nil
    }

    /// True only after the unattended-motion detector has seen the phone resting.
    /// Turning the phone makes this false, so a compass swing from that turn is not a heading hit.
    func phoneIsStill(at timestamp: TimeInterval) -> Bool {
        guard case .watching = phase else { return false }
        return isResting(at: timestamp) && !isWalking(at: timestamp)
    }

    mutating func ingest(motion frame: DeviceMotionFrame) -> [LeadHit] {
        switch phase {
        case .waitingForStillness:
            observeStillness(frame)
            return []
        case .learning(let startedAt):
            continueLearning(frame, startedAt: startedAt)
            return []
        case .watching:
            return detectMotion(frame)
        }
    }

    mutating func ingest(pressure frame: PressureFrame) -> [LeadHit] {
        switch phase {
        case .learning(let startedAt) where frame.timestamp >= startedAt:
            learningPressure.append(frame.kilopascals)
            return []
        case .watching:
            return detectPressure(frame)
        default:
            return []
        }
    }

    private func isWalking(at timestamp: TimeInterval) -> Bool {
        guard let lastStepChange else { return false }
        return timestamp - lastStepChange < 2.5
    }

    private func isQuiet(_ frame: DeviceMotionFrame) -> Bool {
        frame.userAcceleration.magnitude < 0.06
            && frame.rotationRate.magnitude < 0.40
            && !isWalking(at: frame.timestamp)
    }

    private mutating func observeStillness(_ frame: DeviceMotionFrame) {
        guard isQuiet(frame) else {
            stillSince = nil
            return
        }
        if stillSince == nil {
            stillSince = frame.timestamp
        }
        if let stillSince, frame.timestamp - stillSince >= 0.8 {
            phase = .learning(startedAt: frame.timestamp)
            learningMotion = [frame]
            learningPressure = []
            learningRaw = []
            if let raw = frame.rawField {
                learningRaw.append(raw.magnitude)
            }
        }
    }

    private mutating func continueLearning(_ frame: DeviceMotionFrame, startedAt: TimeInterval) {
        let disturbed = frame.userAcceleration.magnitude > 0.15
            || frame.rotationRate.magnitude > 1
            || isWalking(at: frame.timestamp)
        if disturbed {
            phase = .waitingForStillness
            stillSince = nil
            learningMotion = []
            learningPressure = []
            learningRaw = []
            return
        }
        learningMotion.append(frame)
        if let raw = frame.rawField {
            learningRaw.append(raw.magnitude)
        }
        if frame.timestamp - startedAt >= 5 {
            finishBaseline()
            phase = .watching
            stillSince = frame.timestamp
        }
    }

    private mutating func finishBaseline() {
        let magnitudes = learningMotion.map(\.calibratedField.magnitude)
        baselineMagnitude = mean(magnitudes)
        baselineVector = meanVector(learningMotion.map(\.calibratedField))
        baselineAccuracy = learningMotion.map(\.fieldAccuracy).max(by: { $0.rawValue < $1.rawValue }) ?? .unknown
        if learningRaw.isEmpty {
            baselineRawMagnitude = nil
        } else {
            baselineRawMagnitude = mean(learningRaw)
        }
        magneticReady = baselineMagnitude > 8 || baselineAccuracy.rawValue >= FieldAccuracy.medium.rawValue
        if !learningPressure.isEmpty {
            slowPressure = mean(learningPressure)
        }
        recentPressure = []
        pressureArmed = true
    }

    private mutating func detectMotion(_ frame: DeviceMotionFrame) -> [LeadHit] {
        let acceleration = frame.userAcceleration.magnitude
        let rotation = frame.rotationRate.magnitude
        let walking = isWalking(at: frame.timestamp)
        let wasResting = isResting(at: frame.timestamp)
        if acceleration < 0.08 && rotation < 0.45 && !walking {
            if stillSince == nil { stillSince = frame.timestamp }
        } else {
            stillSince = nil
        }

        recentAcceleration = remember(acceleration, in: recentAcceleration)
        recentRotation = remember(rotation, in: recentRotation)

        var hits: [LeadHit] = []
        let magnitude = frame.calibratedField.magnitude
        let vectorDistance = frame.calibratedField.distance(to: baselineVector)
        recentFieldMagnitude = remember(magnitude, in: recentFieldMagnitude)
        recentVectorDistance = remember(vectorDistance, in: recentVectorDistance)
        if let raw = frame.rawField {
            recentRawMagnitude = remember(raw.magnitude, in: recentRawMagnitude)
        }

        if magneticReady {
            let magnitudeDelta = abs(magnitude - baselineMagnitude)
            let fieldLimit = sensitivity.scaled(DetectionLimit.fieldMagnitude)
            if magnitudeDelta >= fieldLimit {
                hits.append(contentsOf: emit(
                    kind: .magneticDisturbance,
                    feature: "Field magnitude",
                    magnitude: magnitudeDelta,
                    threshold: fieldLimit,
                    timestamp: frame.timestamp,
                    samples: recentFieldMagnitude
                ))
            }
            let vectorLimit = sensitivity.scaled(DetectionLimit.vectorJump)
            if vectorDistance >= vectorLimit {
                hits.append(contentsOf: emit(
                    kind: .magneticDisturbance,
                    feature: "Vector jump",
                    magnitude: vectorDistance,
                    threshold: vectorLimit,
                    timestamp: frame.timestamp,
                    samples: recentVectorDistance
                ))
            }
        }

        let accuracyDropped = baselineAccuracy.rawValue >= FieldAccuracy.medium.rawValue
            && frame.fieldAccuracy.rawValue <= FieldAccuracy.low.rawValue
            && frame.fieldAccuracy != .unknown
        if accuracyDropped {
            hits.append(contentsOf: emit(
                kind: .magneticDisturbance,
                feature: "Field accuracy",
                magnitude: Double(baselineAccuracy.rawValue - frame.fieldAccuracy.rawValue),
                threshold: DetectionLimit.accuracyFloor,
                timestamp: frame.timestamp,
                samples: recentFieldMagnitude
            ))
        }

        if let baselineRawMagnitude, let raw = frame.rawField,
           frame.fieldAccuracy == .unreliable || frame.fieldAccuracy == .low {
            let rawDelta = abs(raw.magnitude - baselineRawMagnitude)
            let rawLimit = sensitivity.scaled(DetectionLimit.rawField)
            if rawDelta >= rawLimit {
                hits.append(contentsOf: emit(
                    kind: .magneticDisturbance,
                    feature: "Raw field",
                    magnitude: rawDelta,
                    threshold: rawLimit,
                    timestamp: frame.timestamp,
                    samples: recentRawMagnitude
                ))
            }
        }

        if wasResting && !walking {
            let accelerationLimit = sensitivity.scaled(DetectionLimit.userAcceleration)
            if acceleration >= accelerationLimit {
                hits.append(contentsOf: emit(
                    kind: .unattendedMotion,
                    feature: "User acceleration",
                    magnitude: acceleration,
                    threshold: accelerationLimit,
                    timestamp: frame.timestamp,
                    samples: recentAcceleration
                ))
            }
            let rotationLimit = sensitivity.scaled(DetectionLimit.rotation)
            if rotation >= rotationLimit {
                hits.append(contentsOf: emit(
                    kind: .unattendedMotion,
                    feature: "Rotation",
                    magnitude: rotation,
                    threshold: rotationLimit,
                    timestamp: frame.timestamp,
                    samples: recentRotation
                ))
            }
        }
        return hits
    }

    private func isResting(at timestamp: TimeInterval) -> Bool {
        guard let stillSince else { return false }
        return timestamp - stillSince >= 1
    }

    private mutating func detectPressure(_ frame: PressureFrame) -> [LeadHit] {
        recentPressure.append(frame.kilopascals)
        if recentPressure.count > 3 {
            recentPressure.removeFirst()
        }
        guard let slow = slowPressure else {
            slowPressure = frame.kilopascals
            return []
        }
        let short = mean(recentPressure)
        let delta = short - slow
        var hits: [LeadHit] = []
        let pressureLimit = sensitivity.scaled(DetectionLimit.pressureStep)
        if abs(delta) >= pressureLimit && pressureArmed {
            pressureArmed = false
            hits = emit(
                kind: .pressureChange,
                feature: "Pressure step",
                magnitude: delta,
                threshold: pressureLimit,
                timestamp: frame.timestamp,
                samples: recentPressure
            )
        } else if abs(delta) < 0.01 {
            pressureArmed = true
        }
        let alpha = 1 - exp(-1.0 / 45.0)
        slowPressure = slow + alpha * (frame.kilopascals - slow)
        return hits
    }

    private mutating func emit(
        kind: LeadKind,
        feature: String,
        magnitude: Double,
        threshold: Double,
        timestamp: TimeInterval,
        samples: [Double]
    ) -> [LeadHit] {
        let key = "\(kind.rawValue)-\(feature)"
        if let until = cooldownUntil[key], timestamp < until {
            return []
        }
        cooldownUntil[key] = timestamp + 6
        return [
            LeadHit(
                id: UUID(),
                kind: kind,
                feature: feature,
                magnitude: magnitude,
                threshold: threshold,
                timestamp: timestamp,
                samples: samples
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

    private func mean(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        return values.reduce(0, +) / Double(values.count)
    }

    private func meanVector(_ values: [Vector3]) -> Vector3 {
        guard !values.isEmpty else { return .zero }
        let count = Double(values.count)
        return Vector3(
            x: values.reduce(0) { $0 + $1.x } / count,
            y: values.reduce(0) { $0 + $1.y } / count,
            z: values.reduce(0) { $0 + $1.z } / count
        )
    }
}
