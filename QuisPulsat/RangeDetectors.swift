import Foundation

struct DepthCell: Equatable, Sendable {
    var depth: Double
    var confidence: Int
}

struct DepthFrame: Equatable, Sendable {
    var timestamp: TimeInterval
    var cells: [DepthCell]
}

struct RadioFrame: Equatable, Sendable {
    var timestamp: TimeInterval
    var identifier: String
    var rssi: Double
    var advertisement: String
}

/// Learns open LiDAR cells, then flags a closer reading in one of those cells.
/// The hit stores depth and confidence. It does not name what entered the space.
struct DepthDetector: Equatable {
    var sensitivity = DetectionSensitivity.standard
    private(set) var phase: SoundPhase = .waiting
    private var depthHistory: [[Double]] = []
    private var confidenceHistory: [[Int]] = []
    private var baselineDepth: [Double] = []
    private var baselineConfidence: [Int] = []
    private var recentDepth: [Double] = []
    private var cooldownUntil: TimeInterval = 0

    static let columns = 4
    static let rows = 3
    static let learningText = "Learning the room's empty space."
    static let watchingText = "Watching for something in empty space."

    var statusText: String {
        switch phase {
        case .waiting: ""
        case .learning: Self.learningText
        case .watching: Self.watchingText
        }
    }

    mutating func noteInterruption() {
        phase = .waiting
        depthHistory = []
        confidenceHistory = []
        baselineDepth = []
        baselineConfidence = []
        recentDepth = []
        cooldownUntil = 0
    }

    mutating func ingest(_ frame: DepthFrame) -> [LeadHit] {
        guard frame.cells.count == Self.columns * Self.rows else { return [] }
        switch phase {
        case .waiting:
            phase = .learning(startedAt: frame.timestamp)
            rememberBaseline(frame.cells)
            return []
        case .learning(let startedAt):
            rememberBaseline(frame.cells)
            if frame.timestamp - startedAt >= DetectionLimit.depthBaseline {
                finishBaseline()
                phase = .watching
            }
            return []
        case .watching:
            recentDepth = remember(centerDepth(frame.cells), in: recentDepth)
            return detect(frame)
        }
    }

    private mutating func rememberBaseline(_ cells: [DepthCell]) {
        if depthHistory.count != cells.count {
            depthHistory = Array(repeating: [], count: cells.count)
            confidenceHistory = Array(repeating: [], count: cells.count)
        }
        for index in cells.indices {
            if cells[index].depth > 0 {
                depthHistory[index].append(cells[index].depth)
            }
            confidenceHistory[index].append(cells[index].confidence)
        }
    }

    private mutating func finishBaseline() {
        baselineDepth = depthHistory.map { values in
            values.isEmpty ? 0 : SignalMeasure.median(values)
        }
        baselineConfidence = confidenceHistory.map { values in
            guard !values.isEmpty else { return 0 }
            return values.sorted()[values.count / 2]
        }
    }

    private func centerDepth(_ cells: [DepthCell]) -> Double {
        let index = (Self.rows / 2) * Self.columns + (Self.columns / 2)
        guard cells.indices.contains(index) else { return 0 }
        return cells[index].depth
    }

    private mutating func detect(_ frame: DepthFrame) -> [LeadHit] {
        let limit = sensitivity.scaled(DetectionLimit.depthClosure)
        var best: (closure: Double, confidence: Int)?
        for index in frame.cells.indices {
            let cell = frame.cells[index]
            let base = baselineDepth[index]
            guard base >= 0.5, baselineConfidence[index] >= DetectionLimit.depthConfidence else { continue }
            guard cell.depth > 0, cell.confidence >= DetectionLimit.depthConfidence else { continue }
            let closure = base - cell.depth
            guard closure >= limit else { continue }
            if best == nil || closure > best?.closure ?? 0 {
                best = (closure, cell.confidence)
            }
        }
        guard let best, frame.timestamp >= cooldownUntil else { return [] }
        cooldownUntil = frame.timestamp + 6
        return [
            LeadHit(
                id: UUID(),
                kind: .depth,
                feature: "Empty space",
                magnitude: best.closure,
                threshold: limit,
                timestamp: frame.timestamp,
                samples: recentDepth,
                detail: "confidence \(best.confidence)"
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

/// Learns the radios already in the room, then flags a new advertisement or a sharp RSSI change.
/// The hit keeps the advertisement text and the RSSI. It does not name the device.
struct RadioDetector: Equatable {
    var sensitivity = DetectionSensitivity.standard
    private(set) var phase: SoundPhase = .waiting
    private var known: [String: Double] = [:]
    private var recent: [String: [Double]] = [:]
    private var cooldownUntil: [String: TimeInterval] = [:]

    static let learningText = "Learning the radios already here."
    static let watchingText = "Watching for a new radio or a sharp signal change."

    var statusText: String {
        switch phase {
        case .waiting: ""
        case .learning: Self.learningText
        case .watching: Self.watchingText
        }
    }

    mutating func noteInterruption() {
        phase = .waiting
        known = [:]
        recent = [:]
        cooldownUntil = [:]
    }

    mutating func ingest(_ frame: RadioFrame) -> [LeadHit] {
        recent[frame.identifier] = remember(frame.rssi, in: recent[frame.identifier] ?? [])
        switch phase {
        case .waiting:
            phase = .learning(startedAt: frame.timestamp)
            known[frame.identifier] = frame.rssi
            return []
        case .learning(let startedAt):
            known[frame.identifier] = frame.rssi
            if frame.timestamp - startedAt >= DetectionLimit.radioBaseline {
                phase = .watching
            }
            return []
        case .watching:
            return detect(frame)
        }
    }

    private mutating func detect(_ frame: RadioFrame) -> [LeadHit] {
        let samples = recent[frame.identifier] ?? [frame.rssi]
        if known[frame.identifier] == nil {
            known[frame.identifier] = frame.rssi
            return emit(
                key: "\(frame.identifier)|new",
                feature: "New advertisement",
                magnitude: frame.rssi,
                threshold: 0,
                frame: frame,
                samples: samples
            )
        }
        let previous = known[frame.identifier] ?? frame.rssi
        let delta = frame.rssi - previous
        known[frame.identifier] = frame.rssi
        let limit = sensitivity.scaled(DetectionLimit.rssiJump)
        guard abs(delta) >= limit else { return [] }
        return emit(
            key: "\(frame.identifier)|rssi",
            feature: "RSSI change",
            magnitude: delta,
            threshold: limit,
            frame: frame,
            samples: samples
        )
    }

    private mutating func emit(
        key: String,
        feature: String,
        magnitude: Double,
        threshold: Double,
        frame: RadioFrame,
        samples: [Double]
    ) -> [LeadHit] {
        if let until = cooldownUntil[key], frame.timestamp < until {
            return []
        }
        cooldownUntil[key] = frame.timestamp + 6
        return [
            LeadHit(
                id: UUID(),
                kind: .radio,
                feature: feature,
                magnitude: magnitude,
                threshold: threshold,
                timestamp: frame.timestamp,
                samples: samples,
                detail: frame.advertisement
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
