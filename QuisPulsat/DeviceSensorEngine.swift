import ARKit
import AVFoundation
import CoreBluetooth
import CoreLocation
import CoreMotion
import CoreNFC
import NearbyInteraction
import NetworkExtension
import UIKit

/// Streams the phone's sensors for the live widgets.
/// Motion, magnetometer, and barometer start immediately.
/// The other sensors start when permission is already granted, or when a widget is tapped.
@MainActor
final class DeviceSensorEngine: NSObject, SensorEngine {
    private var report: ((SensorKind, String?, Double?, Double?, SensorStatus?, String?, [Double]?, [NearbySighting]?) -> Void)?
    private var onMotion: ((DeviceMotionFrame) -> Void)?
    private var onPressure: ((PressureFrame) -> Void)?
    private var onSteps: ((Int, TimeInterval) -> Void)?
    private var onSound: ((SoundFrame) -> Void)?
    private var onHeading: ((HeadingFrame) -> Void)?
    private var onBrightness: ((BrightnessFrame) -> Void)?
    private var onDepthFrame: ((DepthFrame) -> Void)?
    private var onRadio: ((RadioFrame) -> Void)?
    private var onPicture: ((RoomPicture) -> Void)?
    private var started = false
    private var latestRaw: Vector3?
    private var clockOrigin: ContinuousClock.Instant?
    private let clock = ContinuousClock()
    private let motion = CMMotionManager()
    private let altimeter = CMAltimeter()
    private let pedometer = CMPedometer()
    private var locationFeed: LocationFeed?
    private var audioFeed: AudioLevelFeed?
    private var visionFeed: VisionFeed?
    private var bluetoothFeed: BluetoothFeed?
    private var nearbySightings: [String: NearbySighting] = [:]
    private var nearbyRefresh: Task<Void, Never>?
    private var bluetoothDenied = false
    private var nearbyRange = DetectionSensitivity.standard.nearbyFeet
    private var depthCells: [DepthCell] = []
    private var wifiName: String?
    private var surveyHold = RoomSurvey.Hold()
    private var wifiTask: Task<Void, Never>?
    private var faceFeed: FaceFeed?
    private var tagFeed: TagFeed?
    private let activity = CMMotionActivityManager()
    private var altitudeStarted = false
    private var proximityObserver: NSObjectProtocol?
    private var thermalObserver: NSObjectProtocol?

    func bind(_ update: @escaping (SensorKind, String?, Double?, Double?, SensorStatus?, String?, [Double]?, [NearbySighting]?) -> Void) {
        report = update
    }

    func bindSurvey(_ update: @escaping (RoomPicture) -> Void) {
        onPicture = update
    }

    func trackMotion(_ handler: @escaping (DeviceMotionFrame) -> Void) {
        onMotion = handler
    }

    func trackPressure(_ handler: @escaping (PressureFrame) -> Void) {
        onPressure = handler
    }

    func trackSteps(_ handler: @escaping (Int, TimeInterval) -> Void) {
        onSteps = handler
    }

    func trackSound(_ handler: @escaping (SoundFrame) -> Void) {
        onSound = handler
    }

    func trackHeading(_ handler: @escaping (HeadingFrame) -> Void) {
        onHeading = handler
    }

    func trackBrightness(_ handler: @escaping (BrightnessFrame) -> Void) {
        onBrightness = handler
    }

    func trackDepth(_ handler: @escaping (DepthFrame) -> Void) {
        onDepthFrame = handler
    }

    func trackRadio(_ handler: @escaping (RadioFrame) -> Void) {
        onRadio = handler
    }

    func start() {
        guard !started else { return }
        started = true
        if clockOrigin == nil {
            clockOrigin = clock.now
        }
        startMotion()
        startBarometer()
        if CMPedometer.authorizationStatus() == .authorized {
            startPedometer()
        }
        let locationStatus = CLLocationManager().authorizationStatus
        if locationStatus == .authorizedWhenInUse || locationStatus == .authorizedAlways {
            startLocation(request: false)
        }
        if AVAudioApplication.shared.recordPermission == .granted {
            startMicrophone(request: false)
        }
        if AVCaptureDevice.authorizationStatus(for: .video) == .authorized {
            startVision(request: false)
        }
        if CBManager.authorization == .allowedAlways {
            startBluetooth()
        }
        if CMPedometer.authorizationStatus() == .authorized {
            startActivity()
        }
        if locationStatus == .authorizedWhenInUse || locationStatus == .authorizedAlways {
            startAltitude()
        }
        if AVCaptureDevice.authorizationStatus(for: .video) == .authorized,
           !ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) {
            startFace(request: false)
        }
        startProximity()
        startThermal()
        startNearbyMaintenance()
        publishNearby()
    }

    func stop() {
        started = false
        motion.stopDeviceMotionUpdates()
        motion.stopMagnetometerUpdates()
        motion.stopAccelerometerUpdates()
        motion.stopGyroUpdates()
        altimeter.stopRelativeAltitudeUpdates()
        altimeter.stopAbsoluteAltitudeUpdates()
        altitudeStarted = false
        pedometer.stopUpdates()
        activity.stopActivityUpdates()
        locationFeed?.stop()
        audioFeed?.stop()
        visionFeed?.stop()
        bluetoothFeed?.stop()
        faceFeed?.stop()
        tagFeed?.stop()
        nearbyRefresh?.cancel()
        nearbyRefresh = nil
        wifiTask?.cancel()
        wifiTask = nil
        nearbySightings.removeAll()
        depthCells = []
        wifiName = nil
        surveyHold = RoomSurvey.Hold()
        bluetoothDenied = false
        UIDevice.current.isProximityMonitoringEnabled = false
        if let proximityObserver {
            NotificationCenter.default.removeObserver(proximityObserver)
            self.proximityObserver = nil
        }
        if let thermalObserver {
            NotificationCenter.default.removeObserver(thermalObserver)
            self.thermalObserver = nil
        }
    }

    func enable(_ kind: SensorKind) {
        switch kind {
        case .pedometer, .pace:
            startPedometer()
        case .activity:
            startActivity()
        case .compass, .location:
            startLocation(request: true)
        case .altitude:
            startLocation(request: true)
            startAltitude()
        case .microphone:
            startMicrophone(request: true)
        case .camera, .lidar:
            startVision(request: true)
        case .trueDepth:
            startFace(request: true)
        case .survey:
            startBluetooth()
            startProximity()
            startNearbyMaintenance()
            startVision(request: true)
            startLocation(request: true)
            startMicrophone(request: true)
            startWifi()
        case .nearby:
            startBluetooth()
            startProximity()
            startNearbyMaintenance()
        case .bluetooth:
            startBluetooth()
        case .nfc:
            startNFC()
        case .deviceMotion, .magnetometer, .barometer, .accelerometer, .gyroscope, .proximity, .ultraWideband, .thermal:
            break
        }
    }

    func setNearbyRange(_ feet: Double) {
        nearbyRange = min(max(feet, 1), NearbyScan.maxFeet)
        publishNearby()
    }

    private func publish(
        _ kind: SensorKind,
        value: String? = nil,
        reading: Double? = nil,
        secondary: Double? = nil,
        status: SensorStatus? = nil,
        caption: String? = nil,
        bands: [Double]? = nil,
        sightings: [NearbySighting]? = nil
    ) {
        report?(kind, value, reading, secondary, status, caption, bands, sightings)
    }

    private func startMotion() {
        if motion.isDeviceMotionAvailable {
            motion.deviceMotionUpdateInterval = 0.1
            motion.startDeviceMotionUpdates(using: .xMagneticNorthZVertical, to: .main) { [weak self] data, _ in
            guard let data else { return }
            let acceleration = data.userAcceleration
            let rotation = data.rotationRate
            let g = (acceleration.x * acceleration.x + acceleration.y * acceleration.y + acceleration.z * acceleration.z).squareRoot()
            let world = Self.worldField(from: data)
            let microtesla = world.magnitude
            let magnetometerAvailable = self?.motion.isMagnetometerAvailable == true
            let accuracy = Self.accuracy(from: data.magneticField.accuracy)
            Task { @MainActor in
                guard let self else { return }
                let timestamp = self.elapsed()
                let frame = DeviceMotionFrame(
                    timestamp: timestamp,
                    userAcceleration: Vector3(x: acceleration.x, y: acceleration.y, z: acceleration.z),
                    rotationRate: Vector3(x: rotation.x, y: rotation.y, z: rotation.z),
                    calibratedField: world,
                    fieldAccuracy: accuracy,
                    rawField: self.latestRaw
                )
                self.onMotion?(frame)
                self.publish(.deviceMotion, value: SensorValueFormat.g(g), reading: g)
                if magnetometerAvailable {
                    self.publish(.magnetometer, value: SensorValueFormat.microtesla(microtesla), reading: microtesla)
                }
            }
            }
        }
        if motion.isMagnetometerAvailable {
            motion.magnetometerUpdateInterval = 0.1
            motion.startMagnetometerUpdates(to: .main) { [weak self] data, _ in
                guard let field = data?.magneticField else { return }
                let raw = Vector3(x: field.x, y: field.y, z: field.z)
                Task { @MainActor in
                    self?.latestRaw = raw
                }
            }
        }
        if motion.isAccelerometerAvailable {
            motion.accelerometerUpdateInterval = 0.1
            motion.startAccelerometerUpdates(to: .main) { [weak self] data, _ in
                guard let acceleration = data?.acceleration else { return }
                let g = (acceleration.x * acceleration.x + acceleration.y * acceleration.y + acceleration.z * acceleration.z).squareRoot()
                Task { @MainActor in
                    self?.publish(.accelerometer, value: SensorValueFormat.g(g), reading: g, status: .live)
                }
            }
        }
        if motion.isGyroAvailable {
            motion.gyroUpdateInterval = 0.1
            motion.startGyroUpdates(to: .main) { [weak self] data, _ in
                guard let rotation = data?.rotationRate else { return }
                let rate = (rotation.x * rotation.x + rotation.y * rotation.y + rotation.z * rotation.z).squareRoot()
                Task { @MainActor in
                    self?.publish(.gyroscope, value: SensorValueFormat.radiansPerSecond(rate), reading: rate, status: .live)
                }
            }
        }
    }

    private func elapsed() -> TimeInterval {
        guard let clockOrigin else { return 0 }
        let duration = clock.now - clockOrigin
        return Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }

    private static func worldField(from data: CMDeviceMotion) -> Vector3 {
        let rotation = data.attitude.rotationMatrix
        let field = data.magneticField.field
        return Vector3(
            x: rotation.m11 * field.x + rotation.m12 * field.y + rotation.m13 * field.z,
            y: rotation.m21 * field.x + rotation.m22 * field.y + rotation.m23 * field.z,
            z: rotation.m31 * field.x + rotation.m32 * field.y + rotation.m33 * field.z
        )
    }

    private static func accuracy(from accuracy: CMMagneticFieldCalibrationAccuracy) -> FieldAccuracy {
        switch accuracy {
        case .uncalibrated: .unreliable
        case .low: .low
        case .medium: .medium
        case .high: .high
        @unknown default: .unknown
        }
    }

    private func startBarometer() {
        guard CMAltimeter.isRelativeAltitudeAvailable() else { return }
        altimeter.startRelativeAltitudeUpdates(to: .main) { [weak self] data, _ in
            guard let pressure = data?.pressure.doubleValue else { return }
            Task { @MainActor in
                guard let self else { return }
                let timestamp = self.elapsed()
                self.onPressure?(PressureFrame(timestamp: timestamp, kilopascals: pressure))
                self.publish(.barometer, value: SensorValueFormat.kilopascals(pressure), reading: pressure)
            }
        }
    }

    private func startPedometer() {
        guard CMPedometer.isStepCountingAvailable() else { return }
        pedometer.startUpdates(from: Date()) { [weak self] data, _ in
            let steps = data?.numberOfSteps.intValue
            let status = DeviceSensorProbe.permission(from: CMPedometer.authorizationStatus())
            Task { @MainActor in
                guard let self else { return }
                let widgetStatus: SensorStatus = status == .allowed ? .live : (status == .denied ? .denied : .notAsked)
                if let steps, widgetStatus == .live {
                    let timestamp = self.elapsed()
                    self.onSteps?(steps, timestamp)
                    self.publish(.pedometer, value: SensorValueFormat.steps(steps), reading: Double(steps), status: .live)
                    self.publishPace(data)
                } else {
                    self.publish(.pedometer, value: "—", status: widgetStatus)
                    self.publish(.pace, value: "—", status: widgetStatus)
                }
            }
        }
    }

    private func startLocation(request: Bool) {
        if locationFeed == nil {
            let feed = LocationFeed()
            feed.onHeading = { [weak self] heading in
                guard heading.headingAccuracy >= 0, heading.magneticHeading >= 0 else { return }
                guard let self else { return }
                self.publish(
                    .compass,
                    value: SensorValueFormat.degrees(heading.magneticHeading),
                    reading: heading.magneticHeading,
                    status: .live
                )
                self.onHeading?(HeadingFrame(
                    timestamp: self.elapsed(),
                    magneticHeading: heading.magneticHeading,
                    accuracy: heading.headingAccuracy
                ))
            }
            feed.onLocation = { [weak self] location in
                guard location.horizontalAccuracy >= 0 else { return }
                guard let self else { return }
                self.publish(
                    .location,
                    value: SensorValueFormat.coordinate(
                        latitude: location.coordinate.latitude,
                        longitude: location.coordinate.longitude
                    ),
                    reading: location.coordinate.latitude,
                    secondary: location.coordinate.longitude,
                    status: .live
                )
                let moved = self.surveyHold.note(place: SurveyPlace(
                    latitude: location.coordinate.latitude,
                    longitude: location.coordinate.longitude,
                    accuracyMeters: location.horizontalAccuracy
                ))
                if moved {
                    self.depthCells = []
                    self.publishSurvey()
                }
            }
            feed.onAuthorization = { [weak self] status in
                let permission = DeviceSensorProbe.permission(from: status)
                let widgetStatus: SensorStatus = switch permission {
                case .allowed, .notRequired: .live
                case .denied: .denied
                case .notAsked: .notAsked
                }
                self?.publish(.compass, status: widgetStatus)
                self?.publish(.location, status: widgetStatus)
                self?.publish(.altitude, status: widgetStatus)
                if widgetStatus == .live {
                    self?.startAltitude()
                }
                if widgetStatus == .denied {
                    self?.locationFeed?.stop()
                }
            }
            locationFeed = feed
        }
        locationFeed?.start(request: request)
    }

    private var micSpectrum: [Float] = []

    private func startMicrophone(request: Bool) {
        if audioFeed == nil {
            audioFeed = AudioLevelFeed(
                onLevel: { [weak self] decibels in
                    self?.publish(.microphone, value: SensorValueFormat.decibels(decibels), reading: decibels, status: .live)
                },
                onWindow: { [weak self] sampleRate, samples in
                    guard let self else { return }
                    self.micSpectrum.append(contentsOf: samples)
                    if self.micSpectrum.count > 8_192 {
                        self.micSpectrum.removeFirst(self.micSpectrum.count - 8_192)
                    }
                    let bands = Spectrum.levels(samples: self.micSpectrum, sampleRate: sampleRate)
                    self.publish(
                        .microphone,
                        caption: Spectrum.rangeLabel(sampleRate: sampleRate),
                        bands: bands
                    )
                    self.onSound?(SoundFrame(timestamp: self.elapsed(), sampleRate: sampleRate, samples: samples))
                }
            )
        }
        audioFeed?.start(request: request) { [weak self] granted in
            self?.publish(.microphone, value: "—", status: granted ? .live : .denied)
        }
    }

    private func startVision(request: Bool) {
        if visionFeed == nil {
            visionFeed = VisionFeed(
                onMeter: { [weak self] meter in
                    guard let self else { return }
                    self.publish(
                        .camera,
                        value: SensorValueFormat.luma(meter.luma),
                        reading: meter.luma,
                        status: .live,
                        caption: MeterFormat.caption(meter)
                    )
                    self.onBrightness?(BrightnessFrame(timestamp: self.elapsed(), meter: meter))
                },
                onDepth: { [weak self] cells in
                    guard let self, !cells.isEmpty else { return }
                    let center = cells[cells.count / 2]
                    if center.depth > 0 {
                        self.publish(.lidar, value: SensorValueFormat.meters(center.depth), reading: center.depth, status: .live)
                    }
                    self.onDepthFrame?(DepthFrame(timestamp: self.elapsed(), cells: cells))
                    self.depthCells = cells
                    self.publishSurvey()
                }
            )
        }
        visionFeed?.start(request: request) { [weak self] granted in
            let status: SensorStatus = granted ? .live : .denied
            self?.publish(.camera, value: "—", status: status)
            if ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) {
                self?.publish(.lidar, value: "—", status: status)
            }
        }
    }

    private func startBluetooth() {
        if bluetoothFeed == nil {
            bluetoothFeed = BluetoothFeed(
                onSighting: { [weak self] identifier, name, rssi, txPower, advertisement in
                    guard let self else { return }
                    self.onRadio?(RadioFrame(
                        timestamp: self.elapsed(),
                        identifier: identifier,
                        rssi: rssi,
                        advertisement: advertisement
                    ))
                    let id = "bluetooth-\(identifier)"
                    if let sighting = NearbyScan.bluetooth(
                        identifier: identifier,
                        name: name,
                        rssi: rssi,
                        txPower: txPower,
                        advertisement: advertisement,
                        seenAt: Date()
                    ) {
                        self.nearbySightings[id] = sighting
                    } else {
                        self.nearbySightings.removeValue(forKey: id)
                    }
                    self.publishNearby()
                },
                onDenied: { [weak self] in
                    self?.bluetoothDenied = true
                    self?.publishNearby()
                }
            )
        }
        bluetoothFeed?.start()
    }

    private func startNearbyMaintenance() {
        guard nearbyRefresh == nil else { return }
        nearbyRefresh = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                self?.publishNearby()
            }
        }
    }

    private func publishNearby() {
        let now = Date()
        let fresh = NearbyScan.visible(Array(nearbySightings.values), now: now, rangeFeet: NearbyScan.maxFeet)
        let stale = nearbySightings.keys.filter { id in
            guard nearbySightings[id]?.source == .bluetooth else { return false }
            return !fresh.contains { $0.id == id }
        }
        for id in stale {
            nearbySightings.removeValue(forKey: id)
        }
        let shown = fresh.filter { NearbyScan.withinLimit($0.distanceFeet, rangeFeet: nearbyRange) }
        var caption = "Up is the top of the phone"
        if bluetoothDenied {
            caption += " · Bluetooth omitted"
        }
        if NISession.deviceCapabilities.supportsPreciseDistanceMeasurement,
           !shown.contains(where: { $0.source == .ultraWideband }) {
            caption += " · No UWB peer"
        }
        publish(
            .nearby,
            value: SensorValueFormat.nearby(shown.count),
            reading: Double(shown.count),
            status: .live,
            caption: caption,
            sightings: shown
        )
        publishSurvey()
    }

    private func publishSurvey() {
        let shown = NearbyScan.visible(Array(nearbySightings.values), now: Date(), rangeFeet: nearbyRange)
        let fresh = RoomSurvey.picture(
            cells: depthCells,
            columns: DepthDetector.columns,
            rows: DepthDetector.rows,
            sightings: shown,
            wifiName: wifiName,
            rangeFeet: nearbyRange
        )
        onPicture?(surveyHold.apply(to: fresh))
    }

    private func startWifi() {
        guard wifiTask == nil else { return }
        wifiTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                self?.fetchWifi()
                try? await Task.sleep(for: .seconds(8))
            }
        }
    }

    private func fetchWifi() {
        NEHotspotNetwork.fetchCurrent { [weak self] network in
            let name = network?.ssid
            Task { @MainActor in
                guard let self, self.wifiName != name else { return }
                self.wifiName = name
                self.publishSurvey()
            }
        }
    }

    private func publishPace(_ data: CMPedometerData?) {
        guard let data else { return }
        var notes: [String] = []
        if let cadence = data.currentCadence?.doubleValue {
            notes.append(String(format: "%.1f steps/s", cadence))
        }
        if let distance = data.distance?.doubleValue {
            notes.append(SensorValueFormat.meters(distance))
        }
        if let floors = data.floorsAscended?.intValue {
            notes.append("\(floors) floors")
        }
        if let pace = data.currentPace?.doubleValue {
            publish(
                .pace,
                value: SensorValueFormat.pace(pace),
                reading: pace,
                status: .live,
                caption: notes.joined(separator: " · ")
            )
        } else {
            publish(.pace, value: "Still", reading: 0, status: .live, caption: notes.joined(separator: " · "))
        }
    }

    private func startActivity() {
        guard CMMotionActivityManager.isActivityAvailable() else { return }
        activity.startActivityUpdates(to: .main) { [weak self] activity in
            guard let activity else { return }
            let described = Self.describe(activity)
            Task { @MainActor in
                self?.publish(.activity, value: described.name, reading: described.fraction, status: .live)
            }
        }
    }

    private static func describe(_ activity: CMMotionActivity) -> (name: String, fraction: Double) {
        if activity.automotive { return ("Automotive", 0.9) }
        if activity.running { return ("Running", 0.75) }
        if activity.cycling { return ("Cycling", 0.6) }
        if activity.walking { return ("Walking", 0.45) }
        if activity.stationary { return ("Stationary", 0.15) }
        return ("Unknown", 0)
    }

    private func startAltitude() {
        guard CMAltimeter.isAbsoluteAltitudeAvailable(), !altitudeStarted else { return }
        let status = CLLocationManager().authorizationStatus
        guard status == .authorizedWhenInUse || status == .authorizedAlways else { return }
        altitudeStarted = true
        altimeter.startAbsoluteAltitudeUpdates(to: .main) { [weak self] data, _ in
            guard let meters = data?.altitude else { return }
            Task { @MainActor in
                self?.publish(.altitude, value: SensorValueFormat.meters(meters), reading: meters, status: .live)
            }
        }
    }

    private func startProximity() {
        UIDevice.current.isProximityMonitoringEnabled = true
        publishProximity()
        guard proximityObserver == nil else { return }
        proximityObserver = NotificationCenter.default.addObserver(
            forName: UIDevice.proximityStateDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.publishProximity()
            }
        }
    }

    private func publishProximity() {
        let near = UIDevice.current.proximityState
        if let sighting = NearbyScan.proximity(near: near, seenAt: Date()) {
            nearbySightings[sighting.id] = sighting
        } else {
            nearbySightings.removeValue(forKey: "proximity-earpiece")
        }
        publishNearby()
    }

    private func startThermal() {
        publishThermal()
        guard thermalObserver == nil else { return }
        thermalObserver = NotificationCenter.default.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.publishThermal()
            }
        }
    }

    private func publishThermal() {
        let described: (name: String, fraction: Double) = switch ProcessInfo.processInfo.thermalState {
        case .nominal: ("Nominal", 0.15)
        case .fair: ("Fair", 0.4)
        case .serious: ("Serious", 0.7)
        case .critical: ("Critical", 1)
        @unknown default: ("Unknown", 0)
        }
        publish(.thermal, value: described.name, reading: described.fraction, status: .live)
    }

    private func startFace(request: Bool) {
        guard ARFaceTrackingConfiguration.isSupported else { return }
        if faceFeed == nil {
            faceFeed = FaceFeed { [weak self] meters in
                if let meters {
                    self?.publish(.trueDepth, value: SensorValueFormat.meters(meters), reading: meters, status: .live)
                } else {
                    self?.publish(.trueDepth, value: "No face", status: .live)
                }
            }
        }
        let status = AVCaptureDevice.authorizationStatus(for: .video)
        if status == .authorized {
            faceFeed?.start()
            return
        }
        guard request, status == .notDetermined else {
            if status == .denied {
                publish(.trueDepth, value: "—", status: .denied)
            }
            return
        }
        AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
            Task { @MainActor in
                guard let self else { return }
                if granted {
                    self.faceFeed?.start()
                    self.publish(.trueDepth, value: "No face", status: .live)
                } else {
                    self.publish(.trueDepth, value: "—", status: .denied)
                    self.publish(.camera, value: "—", status: .denied)
                }
            }
        }
    }

    private func startNFC() {
        guard NFCNDEFReaderSession.readingAvailable else { return }
        if tagFeed == nil {
            let feed = TagFeed()
            feed.onTag = { [weak self] label in
                Task { @MainActor in
                    guard let self else { return }
                    let sighting = NearbyScan.tag(records: label, seenAt: Date())
                    self.nearbySightings[sighting.id] = sighting
                    self.publishNearby()
                }
            }
            tagFeed = feed
        }
        tagFeed?.start()
    }
}

private final class LocationFeed: NSObject, CLLocationManagerDelegate {
    let manager = CLLocationManager()
    var onHeading: @MainActor (CLHeading) -> Void = { _ in }
    var onLocation: @MainActor (CLLocation) -> Void = { _ in }
    var onAuthorization: @MainActor (CLAuthorizationStatus) -> Void = { _ in }

    func start(request: Bool) {
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyNearestTenMeters
        manager.distanceFilter = 5
        let status = manager.authorizationStatus
        if request, status == .notDetermined {
            manager.requestWhenInUseAuthorization()
            return
        }
        beginUpdates(status: status)
    }

    func stop() {
        manager.stopUpdatingHeading()
        manager.stopUpdatingLocation()
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor in
            self.onAuthorization(status)
        }
        beginUpdates(status: status)
    }

    func locationManager(_ manager: CLLocationManager, didUpdateHeading newHeading: CLHeading) {
        Task { @MainActor in
            self.onHeading(newHeading)
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }
        Task { @MainActor in
            self.onLocation(location)
        }
    }

    private func beginUpdates(status: CLAuthorizationStatus) {
        guard status == .authorizedWhenInUse || status == .authorizedAlways else { return }
        if CLLocationManager.headingAvailable() {
            manager.startUpdatingHeading()
        }
        manager.startUpdatingLocation()
    }
}

private final class AudioLevelFeed {
    private let onLevel: @MainActor (Double) -> Void
    private let onWindow: @MainActor (Double, [Float]) -> Void
    private let engine = AVAudioEngine()
    private let sessionQueue = DispatchQueue(label: "quispulsat.microphone")
    private var started = false
    private var captureGeneration = 0
    private var pending: [Float] = []

    init(
        onLevel: @escaping @MainActor (Double) -> Void,
        onWindow: @escaping @MainActor (Double, [Float]) -> Void
    ) {
        self.onLevel = onLevel
        self.onWindow = onWindow
    }

    func start(request: Bool, permission: @escaping @MainActor (Bool) -> Void) {
        let current = AVAudioApplication.shared.recordPermission
        if current == .granted {
            Task { @MainActor in permission(true) }
            sessionQueue.async { self.begin() }
            return
        }
        guard request, current == .undetermined else {
            if current == .denied {
                Task { @MainActor in permission(false) }
            }
            return
        }
        AVAudioApplication.requestRecordPermission { granted in
            Task { @MainActor in
                permission(granted)
            }
            if granted {
                self.sessionQueue.async { self.begin() }
            }
        }
    }

    func stop() {
        sessionQueue.async {
            self.captureGeneration += 1
            guard self.started else { return }
            self.engine.inputNode.removeTap(onBus: 0)
            self.engine.stop()
            self.started = false
            let session = AVAudioSession.sharedInstance()
            if #available(iOS 27.0, *) {
                session.deactivate(options: .notifyOthersOnDeactivation) { _, _ in }
            } else {
                try? session.setActive(false, options: .notifyOthersOnDeactivation)
            }
        }
    }

    private func begin() {
        guard !started else { return }
        captureGeneration += 1
        let generation = captureGeneration
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playAndRecord, mode: .measurement, options: [.defaultToSpeaker, .mixWithOthers])
            try session.setPreferredSampleRate(48_000)
        } catch {
            return
        }
        let startAfterActivation: (Bool) -> Void = { [weak self] activated in
            self?.sessionQueue.async {
                guard let self else { return }
                guard activated, generation == self.captureGeneration else {
                    if activated {
                        if #available(iOS 27.0, *) {
                            session.deactivate(options: .notifyOthersOnDeactivation) { _, _ in }
                        } else {
                            try? session.setActive(false, options: .notifyOthersOnDeactivation)
                        }
                    }
                    return
                }
                self.startEngine()
            }
        }
        if #available(iOS 27.0, *) {
            session.activate(options: []) { activated, _ in
                startAfterActivation(activated)
            }
        } else {
            do {
                try session.setActive(true)
            } catch {
                return
            }
            startAfterActivation(true)
        }
    }

    private func startEngine() {
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { return }
        let sampleRate = format.sampleRate
        input.installTap(onBus: 0, bufferSize: 2048, format: format) { [weak self, onLevel, onWindow] buffer, _ in
            guard let samples = buffer.floatChannelData?[0] else { return }
            let count = Int(buffer.frameLength)
            guard count > 0 else { return }
            var sum: Float = 0
            for index in 0..<count {
                let sample = samples[index]
                sum += sample * sample
            }
            let rms = sqrt(sum / Float(count))
            let decibels = 20 * log10(max(Double(rms), 1e-7))
            let chunk = Array(UnsafeBufferPointer(start: samples, count: count))
            Task { @MainActor in
                guard let self else { return }
                onLevel(decibels)
                self.pending.append(contentsOf: chunk)
                while self.pending.count >= 2048 {
                    let window = Array(self.pending.prefix(2048))
                    self.pending.removeFirst(2048)
                    onWindow(sampleRate, window)
                }
            }
        }
        do {
            try engine.start()
            started = true
        } catch {
            input.removeTap(onBus: 0)
        }
    }
}

private final class VisionFeed: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, ARSessionDelegate {
    private let onMeter: @MainActor (CameraMeter) -> Void
    private let onDepth: @MainActor ([DepthCell]) -> Void
    private let session = AVCaptureSession()
    private let depthSession = ARSession()
    private let queue = DispatchQueue(label: "quispulsat.camera")
    private var camera: AVCaptureDevice?
    private var lastSample = Date.distantPast
    private var runningCapture = false
    private var runningDepth = false

    init(onMeter: @escaping @MainActor (CameraMeter) -> Void, onDepth: @escaping @MainActor ([DepthCell]) -> Void) {
        self.onMeter = onMeter
        self.onDepth = onDepth
    }

    func start(request: Bool, permission: @escaping @MainActor (Bool) -> Void) {
        let status = AVCaptureDevice.authorizationStatus(for: .video)
        switch status {
        case .authorized:
            Task { @MainActor in permission(true) }
            run()
        case .notDetermined where request:
            AVCaptureDevice.requestAccess(for: .video) { granted in
                Task { @MainActor in
                    permission(granted)
                    if granted { self.run() }
                }
            }
        case .denied, .restricted:
            Task { @MainActor in permission(false) }
        default:
            break
        }
    }

    func stop() {
        if runningCapture {
            queue.async { [session] in
                session.stopRunning()
            }
            runningCapture = false
        }
        if runningDepth {
            depthSession.pause()
            runningDepth = false
        }
    }

    private func run() {
        if ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) {
            guard !runningDepth else { return }
            depthSession.delegate = self
            let configuration = ARWorldTrackingConfiguration()
            configuration.frameSemantics = .sceneDepth
            depthSession.run(configuration)
            runningDepth = true
            return
        }
        guard !runningCapture else { return }
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
              let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input) else { return }
        camera = device
        session.beginConfiguration()
        session.sessionPreset = .low
        session.addInput(input)
        let output = AVCaptureVideoDataOutput()
        output.alwaysDiscardsLateVideoFrames = true
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange]
        output.setSampleBufferDelegate(self, queue: queue)
        guard session.canAddOutput(output) else {
            session.commitConfiguration()
            return
        }
        session.addOutput(output)
        session.commitConfiguration()
        runningCapture = true
        queue.async { [session] in
            session.startRunning()
        }
    }

    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        let now = Date()
        guard now.timeIntervalSince(lastSample) > 0.2 else { return }
        lastSample = now
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let meter = CameraMeter(
            luma: Self.averageLuma(pixelBuffer),
            exposureSeconds: camera.flatMap { Self.positive($0.exposureDuration.seconds) },
            iso: camera.flatMap { Self.positive(Double($0.iso)) },
            aperture: camera.flatMap { Self.positive(Double($0.lensAperture)) }
        )
        let onMeter = onMeter
        Task { @MainActor in
            onMeter(meter)
        }
    }

    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        let now = Date()
        guard now.timeIntervalSince(lastSample) > 0.2 else { return }
        lastSample = now
        let luma = frame.lightEstimate.map { min(max($0.ambientIntensity / 10, 0), 255) }
        let exposure = frame.camera.exposureDuration
        let depthMap = frame.sceneDepth?.depthMap
        let confidenceMap = frame.sceneDepth?.confidenceMap
        let cells = depthMap.map { Self.depthCells(depth: $0, confidence: confidenceMap) } ?? []
        let onMeter = onMeter
        let onDepth = onDepth
        Task { @MainActor in
            if let luma {
                onMeter(CameraMeter(
                    luma: luma,
                    exposureSeconds: Self.positive(exposure),
                    iso: nil,
                    aperture: nil
                ))
            }
            if !cells.isEmpty {
                onDepth(cells)
            }
        }
    }

    private static func positive(_ value: Double) -> Double? {
        guard value.isFinite, value > 0 else { return nil }
        return value
    }

    private static func averageLuma(_ pixelBuffer: CVPixelBuffer) -> Double {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0) else { return 0 }
        let width = CVPixelBufferGetWidthOfPlane(pixelBuffer, 0)
        let height = CVPixelBufferGetHeightOfPlane(pixelBuffer, 0)
        let rowBytes = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)
        let pixels = base.assumingMemoryBound(to: UInt8.self)
        var total = 0
        var count = 0
        var y = 0
        while y < height {
            var x = 0
            while x < width {
                total += Int(pixels[y * rowBytes + x])
                count += 1
                x += 8
            }
            y += 8
        }
        guard count > 0 else { return 0 }
        return Double(total) / Double(count)
    }

    private static func depthCells(depth: CVPixelBuffer, confidence: CVPixelBuffer?) -> [DepthCell] {
        CVPixelBufferLockBaseAddress(depth, .readOnly)
        if let confidence {
            CVPixelBufferLockBaseAddress(confidence, .readOnly)
        }
        defer {
            CVPixelBufferUnlockBaseAddress(depth, .readOnly)
            if let confidence {
                CVPixelBufferUnlockBaseAddress(confidence, .readOnly)
            }
        }
        guard let depthBase = CVPixelBufferGetBaseAddress(depth) else { return [] }
        let depthWidth = CVPixelBufferGetWidth(depth)
        let depthHeight = CVPixelBufferGetHeight(depth)
        guard depthWidth > 0, depthHeight > 0 else { return [] }
        let depthRow = CVPixelBufferGetBytesPerRow(depth) / MemoryLayout<Float32>.size
        let depthPixels = depthBase.assumingMemoryBound(to: Float32.self)
        let confidenceWidth = confidence.map { CVPixelBufferGetWidth($0) } ?? 0
        let confidenceHeight = confidence.map { CVPixelBufferGetHeight($0) } ?? 0
        let confidenceRow = confidence.map { CVPixelBufferGetBytesPerRow($0) } ?? 0
        let confidencePixels = confidence.flatMap { CVPixelBufferGetBaseAddress($0) }?.assumingMemoryBound(to: UInt8.self)
        var cells: [DepthCell] = []
        for row in 0..<DepthDetector.rows {
            for column in 0..<DepthDetector.columns {
                let x = min(depthWidth - 1, (column * depthWidth + depthWidth / 2) / DepthDetector.columns)
                let y = min(depthHeight - 1, (row * depthHeight + depthHeight / 2) / DepthDetector.rows)
                let meters = depthPixels[y * depthRow + x]
                var confidenceValue = 0
                if let confidencePixels, confidenceWidth > 0, confidenceHeight > 0 {
                    let cx = min(confidenceWidth - 1, x * confidenceWidth / depthWidth)
                    let cy = min(confidenceHeight - 1, y * confidenceHeight / depthHeight)
                    confidenceValue = Int(confidencePixels[cy * confidenceRow + cx])
                }
                let depthValue = meters.isFinite && meters > 0 ? Double(meters) : 0
                cells.append(DepthCell(depth: depthValue, confidence: confidenceValue))
            }
        }
        return cells
    }
}

private final class BluetoothFeed: NSObject, CBCentralManagerDelegate {
    private var manager: CBCentralManager?
    private let onSighting: @MainActor (String, String, Double, Double?, String) -> Void
    private let onDenied: @MainActor () -> Void

    init(
        onSighting: @escaping @MainActor (String, String, Double, Double?, String) -> Void,
        onDenied: @escaping @MainActor () -> Void
    ) {
        self.onSighting = onSighting
        self.onDenied = onDenied
    }

    func start() {
        guard manager == nil else { return }
        manager = CBCentralManager(delegate: self, queue: .main, options: [
            CBCentralManagerOptionShowPowerAlertKey: false,
        ])
    }

    func stop() {
        manager?.stopScan()
        manager = nil
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            central.scanForPeripherals(withServices: nil, options: [
                CBCentralManagerScanOptionAllowDuplicatesKey: true,
            ])
        case .unauthorized:
            Task { @MainActor in
                self.onDenied()
            }
        default:
            break
        }
    }

    func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        let summary = Self.advertisementSummary(advertisementData)
        let rssi = RSSI.doubleValue
        let identifier = peripheral.identifier.uuidString
        let localName = advertisementData[CBAdvertisementDataLocalNameKey] as? String
        let name = (localName?.isEmpty == false ? localName : nil) ?? peripheral.name ?? ""
        let txPower = (advertisementData[CBAdvertisementDataTxPowerLevelKey] as? NSNumber)?.doubleValue
        Task { @MainActor in
            self.onSighting(identifier, name, rssi, txPower, summary)
        }
    }

    private static func advertisementSummary(_ data: [String: Any]) -> String {
        var parts: [String] = []
        if let name = data[CBAdvertisementDataLocalNameKey] as? String, !name.isEmpty {
            parts.append(name)
        }
        if let services = data[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID], !services.isEmpty {
            parts.append(services.map(\.uuidString).joined(separator: ", "))
        }
        if let manufacturer = data[CBAdvertisementDataManufacturerDataKey] as? Data, !manufacturer.isEmpty {
            parts.append("mfr \(manufacturer.count) bytes")
        }
        if let connectable = data[CBAdvertisementDataIsConnectable] as? NSNumber {
            parts.append(connectable.boolValue ? "connectable" : "not connectable")
        }
        return parts.isEmpty ? "advertisement" : parts.joined(separator: " · ")
    }
}

private final class FaceFeed: NSObject, ARSessionDelegate {
    private let onDistance: @MainActor (Double?) -> Void
    private let session = ARSession()
    private var lastUpdate = Date.distantPast

    init(onDistance: @escaping @MainActor (Double?) -> Void) {
        self.onDistance = onDistance
    }

    func start() {
        guard ARFaceTrackingConfiguration.isSupported else { return }
        session.delegate = self
        session.run(ARFaceTrackingConfiguration(), options: [.resetTracking, .removeExistingAnchors])
    }

    func stop() {
        session.pause()
    }

    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        let now = Date()
        guard now.timeIntervalSince(lastUpdate) > 0.2 else { return }
        lastUpdate = now
        let meters: Double?
        if let face = frame.anchors.compactMap({ $0 as? ARFaceAnchor }).first {
            let faceColumn = face.transform.columns.3
            let cameraColumn = frame.camera.transform.columns.3
            let dx = faceColumn.x - cameraColumn.x
            let dy = faceColumn.y - cameraColumn.y
            let dz = faceColumn.z - cameraColumn.z
            meters = Double((dx * dx + dy * dy + dz * dz).squareRoot())
        } else {
            meters = nil
        }
        let report = onDistance
        Task { @MainActor in
            report(meters)
        }
    }
}

private final class TagFeed: NSObject, NFCNDEFReaderSessionDelegate {
    var onTag: ((String) -> Void)?
    private var session: NFCNDEFReaderSession?

    func start() {
        guard NFCNDEFReaderSession.readingAvailable else { return }
        session?.invalidate()
        let session = NFCNDEFReaderSession(delegate: self, queue: nil, invalidateAfterFirstRead: false)
        session.alertMessage = "Hold the top of the phone near a tag."
        self.session = session
        session.begin()
    }

    func stop() {
        session?.invalidate()
        session = nil
    }

    func readerSession(_ session: NFCNDEFReaderSession, didDetectNDEFs messages: [NFCNDEFMessage]) {
        let count = messages.reduce(0) { $0 + $1.records.count }
        onTag?(count == 1 ? "1 record" : "\(count) records")
    }

    func readerSession(_ session: NFCNDEFReaderSession, didDetect tags: [any NFCNDEFTag]) {
        guard let tag = tags.first else { return }
        session.connect(to: tag) { error in
            if error != nil {
                session.invalidate(errorMessage: "The tag could not be read.")
                return
            }
            tag.readNDEF { message, _ in
                let count = message?.records.count ?? 0
                let label = count == 1 ? "1 record" : "\(count) records"
                session.alertMessage = count == 0 ? "No NDEF message on this tag." : "Read \(label)."
                self.onTag?(label)
                session.invalidate()
            }
        }
    }

    func readerSession(_ session: NFCNDEFReaderSession, didInvalidateWithError error: Error) {}
}
