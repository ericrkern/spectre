import Foundation

struct SensorWidgetState: Identifiable, Equatable {
    var kind: SensorKind
    var status: SensorStatus
    var value: String
    var reading: Double?
    var secondary: Double?
    var caption: String = ""
    var spectrum: [Double] = []
    var sightings: [NearbySighting] = []
    var picture: RoomPicture = .empty

    var id: SensorKind { kind }

    var displayedValue: String {
        switch status {
        case .live:
            value
        case .notAsked:
            "Tap to allow"
        case .denied:
            "Omitted"
        case .unavailable:
            "—"
        }
    }

    static func inventory(from readings: [SensorKind: SensorReading]) -> [SensorWidgetState] {
        SensorKind.board.map { kind in
            let reading = readings[kind] ?? SensorReading(hardwarePresent: false, permission: .notAsked)
            return SensorWidgetState(kind: kind, status: SensorStatus.resolve(reading), value: "—")
        }
    }
}

enum SensorValueFormat {
    static func g(_ value: Double) -> String {
        String(format: "%.2f g", value)
    }

    static func microtesla(_ value: Double) -> String {
        String(format: "%.1f µT", value)
    }

    static func kilopascals(_ value: Double) -> String {
        String(format: "%.2f kPa", value)
    }

    static func degrees(_ value: Double) -> String {
        "\(Int(value.rounded()))°"
    }

    static func steps(_ value: Int) -> String {
        "\(value) steps"
    }

    static func decibels(_ value: Double) -> String {
        String(format: "%.0f dB", value)
    }

    static func luma(_ value: Double) -> String {
        "\(Int(value.rounded())) luma"
    }

    static func meters(_ value: Double) -> String {
        String(format: "%.2f m", value)
    }

    static func coordinate(latitude: Double, longitude: Double) -> String {
        String(format: "%.2f, %.2f", latitude, longitude)
    }

    static func nearby(_ count: Int) -> String {
        count == 0 ? "None" : count == 1 ? "1 nearby" : "\(count) nearby"
    }

    static func radiansPerSecond(_ value: Double) -> String {
        String(format: "%.2f rad/s", value)
    }

    static func pace(_ secondsPerMeter: Double) -> String {
        String(format: "%.2f s/m", secondsPerMeter)
    }
}

@MainActor
protocol SensorEngine: AnyObject {
    func bind(_ update: @escaping (SensorKind, String?, Double?, Double?, SensorStatus?, String?, [Double]?, [NearbySighting]?) -> Void)
    func trackMotion(_ handler: @escaping (DeviceMotionFrame) -> Void)
    func trackPressure(_ handler: @escaping (PressureFrame) -> Void)
    func trackSteps(_ handler: @escaping (Int, TimeInterval) -> Void)
    func trackSound(_ handler: @escaping (SoundFrame) -> Void)
    func trackHeading(_ handler: @escaping (HeadingFrame) -> Void)
    func trackBrightness(_ handler: @escaping (BrightnessFrame) -> Void)
    func trackDepth(_ handler: @escaping (DepthFrame) -> Void)
    func trackRadio(_ handler: @escaping (RadioFrame) -> Void)
    func start()
    func stop()
    func enable(_ kind: SensorKind)
    func setNearbyRange(_ feet: Double)
    func bindSurvey(_ update: @escaping (RoomPicture) -> Void)
}

@MainActor
final class IdleSensorEngine: SensorEngine {
    func bind(_ update: @escaping (SensorKind, String?, Double?, Double?, SensorStatus?, String?, [Double]?, [NearbySighting]?) -> Void) {}
    func trackMotion(_ handler: @escaping (DeviceMotionFrame) -> Void) {}
    func trackPressure(_ handler: @escaping (PressureFrame) -> Void) {}
    func trackSteps(_ handler: @escaping (Int, TimeInterval) -> Void) {}
    func trackSound(_ handler: @escaping (SoundFrame) -> Void) {}
    func trackHeading(_ handler: @escaping (HeadingFrame) -> Void) {}
    func trackBrightness(_ handler: @escaping (BrightnessFrame) -> Void) {}
    func trackDepth(_ handler: @escaping (DepthFrame) -> Void) {}
    func trackRadio(_ handler: @escaping (RadioFrame) -> Void) {}
    func start() {}
    func stop() {}
    func enable(_ kind: SensorKind) {}
    func setNearbyRange(_ feet: Double) {}
    func bindSurvey(_ update: @escaping (RoomPicture) -> Void) {}
}

@MainActor
@Observable
final class SensorFeed {
    private(set) var widgets: [SensorWidgetState]
    private let engine: any SensorEngine

    init(widgets: [SensorWidgetState], engine: (any SensorEngine)? = nil) {
        self.widgets = widgets
        let engine = engine ?? IdleSensorEngine()
        self.engine = engine
        engine.bind { [weak self] kind, value, reading, secondary, status, caption, spectrum, sightings in
            self?.set(
                kind: kind,
                value: value,
                reading: reading,
                secondary: secondary,
                status: status,
                caption: caption,
                spectrum: spectrum,
                sightings: sightings
            )
        }
        engine.bindSurvey { [weak self] picture in
            self?.setSurvey(picture)
        }
    }

    func start() {
        engine.start()
    }

    func stop() {
        engine.stop()
    }

    func enable(_ kind: SensorKind) {
        engine.enable(kind)
    }

    func setNearbyRange(_ feet: Double) {
        engine.setNearbyRange(feet)
    }

    func trackMotion(_ handler: @escaping (DeviceMotionFrame) -> Void) {
        engine.trackMotion(handler)
    }

    func trackPressure(_ handler: @escaping (PressureFrame) -> Void) {
        engine.trackPressure(handler)
    }

    func trackSteps(_ handler: @escaping (Int, TimeInterval) -> Void) {
        engine.trackSteps(handler)
    }

    func trackSound(_ handler: @escaping (SoundFrame) -> Void) {
        engine.trackSound(handler)
    }

    func trackHeading(_ handler: @escaping (HeadingFrame) -> Void) {
        engine.trackHeading(handler)
    }

    func trackBrightness(_ handler: @escaping (BrightnessFrame) -> Void) {
        engine.trackBrightness(handler)
    }

    func trackDepth(_ handler: @escaping (DepthFrame) -> Void) {
        engine.trackDepth(handler)
    }

    func trackRadio(_ handler: @escaping (RadioFrame) -> Void) {
        engine.trackRadio(handler)
    }

    private func set(
        kind: SensorKind,
        value: String?,
        reading: Double?,
        secondary: Double?,
        status: SensorStatus?,
        caption: String?,
        spectrum: [Double]?,
        sightings: [NearbySighting]?
    ) {
        guard let index = widgets.firstIndex(where: { $0.kind == kind }) else { return }
        var widget = widgets[index]
        if let value {
            widget.value = value
        }
        if let reading {
            widget.reading = reading
        }
        if let secondary {
            widget.secondary = secondary
        }
        if let caption {
            widget.caption = caption
        }
        if let spectrum {
            widget.spectrum = spectrum
        }
        if let sightings {
            widget.sightings = sightings
        }
        if let status, widget.status != .unavailable {
            widget.status = status
        }
        widgets[index] = widget
    }

    private func setSurvey(_ picture: RoomPicture) {
        guard let index = widgets.firstIndex(where: { $0.kind == .survey }) else { return }
        var widget = widgets[index]
        widget.picture = picture
        if let dot = picture.dot {
            widget.value = dot.distanceLabel
            let range = max(picture.rangeFeet, 1)
            widget.reading = 1 - min(1, dot.feet / range)
        } else {
            widget.value = "Clear"
            widget.reading = 0
        }
        widget.caption = "Up is the top of the phone"
        widgets[index] = widget
    }
}
