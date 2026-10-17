import Foundation
import UIKit

struct SavedSensor: Codable, Equatable, Identifiable {
    var kind: String
    var name: String
    var status: String
    var value: String

    var id: String { kind }
}

struct SavedCapture: Codable, Equatable, Identifiable {
    var id: UUID
    var placeName: String
    var savedAt: Date
    var elapsed: String
    var sensors: [SavedSensor]
}

struct SavedDetection: Codable, Equatable, Identifiable {
    var id: UUID
    var placeName: String
    var savedAt: Date
    var elapsed: String
    var kind: String
    var title: String
    var feature: String
    var magnitude: Double
    var magnitudeLabel: String
    var threshold: Double
    var thresholdLabel: String
    var samples: [Double]
    var sampleLabel: String
    var sensors: [SavedSensor]
    var clipWAV: Data? = nil
    var elapsedSeconds: Double? = nil
}

protocol CaptureStoring: AnyObject {
    func load() -> [SavedCapture]
    func save(_ captures: [SavedCapture])
}

protocol DetectionStoring: AnyObject {
    func load() -> [SavedDetection]
    func save(_ detections: [SavedDetection])
}

@MainActor
protocol DetectionAlerting: AnyObject {
    func announce()
}

final class MemoryCaptureStore: CaptureStoring {
    var captures: [SavedCapture] = []

    func load() -> [SavedCapture] { captures }

    func save(_ captures: [SavedCapture]) {
        self.captures = captures
    }
}

final class FileCaptureStore: CaptureStoring {
    private let fileURL: URL
    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()
    private let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    init(fileURL: URL? = nil) {
        if let fileURL {
            self.fileURL = fileURL
        } else {
            let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            self.fileURL = directory.appendingPathComponent("spectre-captures.json")
        }
    }

    func load() -> [SavedCapture] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        return (try? decoder.decode([SavedCapture].self, from: data)) ?? []
    }

    func save(_ captures: [SavedCapture]) {
        let directory = fileURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard let data = try? encoder.encode(captures) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}

final class MemoryDetectionStore: DetectionStoring {
    var detections: [SavedDetection] = []

    func load() -> [SavedDetection] { detections }

    func save(_ detections: [SavedDetection]) {
        self.detections = detections
    }
}

final class FileDetectionStore: DetectionStoring {
    private let fileURL: URL
    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()
    private let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    init(fileURL: URL? = nil) {
        if let fileURL {
            self.fileURL = fileURL
        } else {
            let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            self.fileURL = directory.appendingPathComponent("spectre-detections.json")
        }
    }

    func load() -> [SavedDetection] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        return (try? decoder.decode([SavedDetection].self, from: data)) ?? []
    }

    func save(_ detections: [SavedDetection]) {
        let directory = fileURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard let data = try? encoder.encode(detections) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}

@MainActor
@Observable
final class DashboardController {
    var placeName = ""
    private(set) var captures: [SavedCapture] = []
    private(set) var detections: [SavedDetection] = []
    private(set) var announced: SavedDetection?
    private(set) var announcedCount = 0
    private(set) var watchStatus = InvestigationDetectors.waitingText
    private(set) var soundStatus = ""
    private(set) var headingStatus = ""
    private(set) var brightnessStatus = ""
    private(set) var depthStatus = ""
    private(set) var radioStatus = ""
    var sensitivityLevel = 0.5 {
        didSet {
            feed.setNearbyRange(sensitivity.nearbyFeet)
        }
    }
    var featuredKind: SensorKind = .survey
    let feed: SensorFeed
    private let store: any CaptureStoring
    private let detectionStore: any DetectionStoring
    private let alert: any DetectionAlerting
    private let clockSource = ContinuousClock()
    private var sessionClock: SessionClock?
    private var detectors = InvestigationDetectors()
    private let tone = WidgetTonePlayer()
    private var sound = SoundDetector()
    private var heading = HeadingDetector()
    private var brightness = BrightnessDetector()
    private var depth = DepthDetector()
    private var radio = RadioDetector()

    init(
        feed: SensorFeed? = nil,
        store: (any CaptureStoring)? = nil,
        detections: (any DetectionStoring)? = nil,
        alert: (any DetectionAlerting)? = nil
    ) {
        if let feed {
            self.feed = feed
        } else {
            self.feed = SensorFeed(
                widgets: SensorWidgetState.inventory(from: DeviceSensorProbe().readings()),
                engine: DeviceSensorEngine()
            )
        }
        let store = store ?? FileCaptureStore()
        self.store = store
        self.captures = store.load()
        let detectionStore = detections ?? FileDetectionStore()
        self.detectionStore = detectionStore
        self.detections = detectionStore.load()
        self.alert = alert ?? ToneDetectionAlert()
    }

    var canCapture: Bool {
        !trimmedPlaceName.isEmpty
    }

    var leadGroups: [LeadGroup] {
        LeadTimeline.groups(detections)
    }

    var sensitivity: DetectionSensitivity {
        DetectionSensitivity(level: sensitivityLevel)
    }

    func activate() {
        feed.trackMotion { [weak self] frame in
            guard let self else { return }
            self.detectors.sensitivity = self.sensitivity
            self.record(self.detectors.ingest(motion: frame))
        }
        feed.trackPressure { [weak self] frame in
            guard let self else { return }
            self.detectors.sensitivity = self.sensitivity
            self.record(self.detectors.ingest(pressure: frame))
        }
        feed.trackSteps { [weak self] steps, timestamp in
            self?.detectors.noteSteps(steps, at: timestamp)
        }
        feed.trackSound { [weak self] frame in
            guard let self else { return }
            self.sound.sensitivity = self.sensitivity
            let hits = self.sound.ingest(frame)
            self.soundStatus = self.sound.statusText
            self.record(hits)
        }
        feed.trackHeading { [weak self] frame in
            guard let self else { return }
            self.heading.sensitivity = self.sensitivity
            let hits = self.heading.ingest(frame, phoneIsStill: self.detectors.phoneIsStill(at: frame.timestamp))
            self.headingStatus = self.heading.statusText
            self.record(hits)
        }
        feed.trackBrightness { [weak self] frame in
            guard let self else { return }
            self.brightness.sensitivity = self.sensitivity
            let hits = self.brightness.ingest(frame)
            self.brightnessStatus = self.brightness.statusText
            self.record(hits)
        }
        feed.trackDepth { [weak self] frame in
            guard let self else { return }
            self.depth.sensitivity = self.sensitivity
            let hits = self.depth.ingest(frame)
            self.depthStatus = self.depth.statusText
            self.record(hits)
        }
        feed.trackRadio { [weak self] frame in
            guard let self else { return }
            self.radio.sensitivity = self.sensitivity
            let hits = self.radio.ingest(frame)
            self.radioStatus = self.radio.statusText
            self.record(hits)
        }
        if sessionClock == nil {
            sessionClock = SessionClock(origin: clockSource.now, wallClockStart: Date())
        }
        tone.start { [weak self] in
            guard let self, let widget = self.feed.widgets.first(where: { $0.kind == self.featuredKind }) else { return nil }
            return WidgetMetric.level(widget)
        }
        feed.setNearbyRange(sensitivity.nearbyFeet)
        feed.start()
        if featuredKind == .survey {
            feed.enable(.survey)
        }
    }

    func suspend() {
        tone.stop()
        detectors.noteInterruption()
        sound.noteInterruption()
        heading.noteInterruption()
        brightness.noteInterruption()
        depth.noteInterruption()
        radio.noteInterruption()
        soundStatus = sound.statusText
        headingStatus = heading.statusText
        brightnessStatus = brightness.statusText
        depthStatus = depth.statusText
        radioStatus = radio.statusText
        feed.stop()
    }

    func elapsedLabel(at instant: ContinuousClock.Instant) -> String {
        guard let sessionClock else { return ElapsedTimeFormat.string(for: .zero) }
        return ElapsedTimeFormat.string(for: sessionClock.elapsed(at: instant))
    }

    func focus(_ kind: SensorKind) {
        featuredKind = kind
        if kind == .nearby || kind == .survey {
            feed.enable(kind)
        } else {
            enable(kind)
        }
    }

    func enable(_ kind: SensorKind) {
        guard let widget = feed.widgets.first(where: { $0.kind == kind }) else { return }
        switch widget.status {
        case .notAsked:
            feed.enable(kind)
        case .denied:
            guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
            UIApplication.shared.open(url)
        case .live, .unavailable:
            break
        }
    }

    func capture() {
        let name = trimmedPlaceName
        guard !name.isEmpty else { return }
        let capture = SavedCapture(
            id: UUID(),
            placeName: name,
            savedAt: Date(),
            elapsed: elapsedLabel(at: clockSource.now),
            sensors: sensorSnapshot()
        )
        captures.insert(capture, at: 0)
        store.save(captures)
    }

    func record(_ hits: [LeadHit]) {
        watchStatus = detectors.statusText
        guard !hits.isEmpty else { return }
        let wallTime = Date()
        let place = trimmedPlaceName.isEmpty ? "Unnamed" : trimmedPlaceName
        let sensors = sensorSnapshot()
        let saved = hits.map { hit in
            SavedDetection(
                id: hit.id,
                placeName: place,
                savedAt: wallTime,
                elapsed: ElapsedTimeFormat.string(for: .seconds(hit.timestamp)),
                kind: hit.kind.rawValue,
                title: hit.kind.title,
                feature: hit.feature,
                magnitude: hit.magnitude,
                magnitudeLabel: hit.magnitudeLabel,
                threshold: hit.threshold,
                thresholdLabel: hit.thresholdLabel,
                samples: hit.samples,
                sampleLabel: hit.sampleLabel,
                sensors: sensors,
                clipWAV: hit.clipWAV,
                elapsedSeconds: hit.timestamp
            )
        }
        detections.insert(contentsOf: saved, at: 0)
        if detections.count > 200 {
            detections.removeLast(detections.count - 200)
        }
        detectionStore.save(detections)
        announced = saved[0]
        announcedCount = saved.count
        tone.stir()
        alert.announce()
    }

    private func sensorSnapshot() -> [SavedSensor] {
        feed.widgets.map { widget in
            SavedSensor(
                kind: widget.kind.rawValue,
                name: widget.kind.displayName,
                status: widget.status.label,
                value: widget.caption.isEmpty ? widget.displayedValue : "\(widget.displayedValue) · \(widget.caption)"
            )
        }
    }

    private var trimmedPlaceName: String {
        placeName.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
