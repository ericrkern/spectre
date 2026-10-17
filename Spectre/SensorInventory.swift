import ARKit
import AVFoundation
import CoreBluetooth
import CoreLocation
import CoreMotion
import CoreNFC
import Foundation
import NearbyInteraction

enum SensorKind: String, CaseIterable, Identifiable, Hashable {
    case survey
    case deviceMotion
    case magnetometer
    case barometer
    case pedometer
    case compass
    case microphone
    case camera
    case lidar
    case nearby
    case location
    case accelerometer
    case gyroscope
    case altitude
    case pace
    case activity
    case trueDepth
    case thermal
    case bluetooth
    case proximity
    case ultraWideband
    case nfc

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .survey: "Anomalies"
        case .deviceMotion: "Device motion"
        case .magnetometer: "Magnetometer"
        case .barometer: "Barometer"
        case .pedometer: "Pedometer"
        case .compass: "Compass"
        case .microphone: "Microphone"
        case .camera: "Camera"
        case .lidar: "LiDAR"
        case .nearby: "Devices nearby"
        case .bluetooth: "Bluetooth"
        case .location: "Location"
        case .accelerometer: "Accelerometer"
        case .gyroscope: "Gyroscope"
        case .altitude: "Altitude"
        case .pace: "Pace"
        case .activity: "Activity"
        case .proximity: "Proximity"
        case .trueDepth: "TrueDepth"
        case .ultraWideband: "Ultra Wideband"
        case .nfc: "NFC"
        case .thermal: "Thermal"
        }
    }

    /// Bluetooth, NFC, Ultra Wideband, and proximity feed the devices-nearby scan.
    var isNearbySource: Bool {
        switch self {
        case .bluetooth, .nfc, .ultraWideband, .proximity: true
        default: false
        }
    }

    static var board: [SensorKind] {
        allCases.filter { !$0.isNearbySource }
    }
}

enum SensorPermission: Equatable {
    case notRequired
    case notAsked
    case allowed
    case denied
}

struct SensorReading: Equatable {
    var hardwarePresent: Bool
    var permission: SensorPermission
}

enum SensorStatus: Equatable {
    case live
    case unavailable
    case denied
    case notAsked

    var label: String {
        switch self {
        case .live: "Live"
        case .unavailable: "Unavailable"
        case .denied: "Denied"
        case .notAsked: "Not asked"
        }
    }

    var detail: String {
        switch self {
        case .live: "On this phone for the session."
        case .unavailable: "This phone does not have this sensor."
        case .denied: "This lead is omitted."
        case .notAsked: "Permission waits until this lead is added."
        }
    }

    static func resolve(_ reading: SensorReading) -> SensorStatus {
        guard reading.hardwarePresent else { return .unavailable }
        switch reading.permission {
        case .notRequired, .allowed:
            return .live
        case .denied:
            return .denied
        case .notAsked:
            return .notAsked
        }
    }
}

struct SensorSnapshot: Identifiable, Equatable {
    var kind: SensorKind
    var status: SensorStatus

    var id: SensorKind { kind }
}

protocol SensorProbe {
    func readings() -> [SensorKind: SensorReading]
}

struct StaticSensorProbe: SensorProbe {
    var readingsByKind: [SensorKind: SensorReading]

    func readings() -> [SensorKind: SensorReading] {
        readingsByKind
    }
}

/// Reads hardware and existing permission state.
/// Does not start a sensor and does not request access.
struct DeviceSensorProbe: SensorProbe {
    func readings() -> [SensorKind: SensorReading] {
        let motion = CMMotionManager()
        let pedometerPermission = Self.permission(from: CMPedometer.authorizationStatus())
        let locationPermission = Self.permission(from: CLLocationManager().authorizationStatus)
        let cameraPermission = Self.permission(from: AVCaptureDevice.authorizationStatus(for: .video))
        let microphonePermission = Self.permission(from: AVAudioApplication.shared.recordPermission)
        let bluetoothPermission = Self.permission(from: CBManager.authorization)
        let hasCamera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) != nil

        return [
            .survey: SensorReading(
                hardwarePresent: true,
                permission: .notRequired
            ),
            .deviceMotion: SensorReading(
                hardwarePresent: motion.isDeviceMotionAvailable,
                permission: .notRequired
            ),
            .magnetometer: SensorReading(
                hardwarePresent: motion.isMagnetometerAvailable,
                permission: .notRequired
            ),
            .barometer: SensorReading(
                hardwarePresent: CMAltimeter.isRelativeAltitudeAvailable(),
                permission: .notRequired
            ),
            .pedometer: SensorReading(
                hardwarePresent: CMPedometer.isStepCountingAvailable(),
                permission: pedometerPermission
            ),
            .compass: SensorReading(
                hardwarePresent: CLLocationManager.headingAvailable(),
                permission: locationPermission
            ),
            .microphone: SensorReading(
                hardwarePresent: true,
                permission: microphonePermission
            ),
            .camera: SensorReading(
                hardwarePresent: hasCamera,
                permission: cameraPermission
            ),
            .lidar: SensorReading(
                hardwarePresent: ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth),
                permission: cameraPermission
            ),
            .nearby: SensorReading(
                hardwarePresent: true,
                permission: .notRequired
            ),
            .bluetooth: SensorReading(
                hardwarePresent: true,
                permission: bluetoothPermission
            ),
            .location: SensorReading(
                hardwarePresent: true,
                permission: locationPermission
            ),
            .accelerometer: SensorReading(
                hardwarePresent: motion.isAccelerometerAvailable,
                permission: .notRequired
            ),
            .gyroscope: SensorReading(
                hardwarePresent: motion.isGyroAvailable,
                permission: .notRequired
            ),
            .altitude: SensorReading(
                hardwarePresent: CMAltimeter.isAbsoluteAltitudeAvailable(),
                permission: locationPermission
            ),
            .pace: SensorReading(
                hardwarePresent: CMPedometer.isStepCountingAvailable(),
                permission: pedometerPermission
            ),
            .activity: SensorReading(
                hardwarePresent: CMMotionActivityManager.isActivityAvailable(),
                permission: pedometerPermission
            ),
            .proximity: SensorReading(
                hardwarePresent: true,
                permission: .notRequired
            ),
            .trueDepth: SensorReading(
                hardwarePresent: ARFaceTrackingConfiguration.isSupported,
                permission: cameraPermission
            ),
            .ultraWideband: SensorReading(
                hardwarePresent: NISession.deviceCapabilities.supportsPreciseDistanceMeasurement,
                permission: .notRequired
            ),
            .nfc: SensorReading(
                hardwarePresent: NFCNDEFReaderSession.readingAvailable,
                permission: .notRequired
            ),
            .thermal: SensorReading(
                hardwarePresent: true,
                permission: .notRequired
            ),
        ]
    }

    static func permission(from status: CMAuthorizationStatus) -> SensorPermission {
        switch status {
        case .notDetermined: .notAsked
        case .authorized: .allowed
        case .denied, .restricted: .denied
        @unknown default: .notAsked
        }
    }

    static func permission(from status: CLAuthorizationStatus) -> SensorPermission {
        switch status {
        case .notDetermined: .notAsked
        case .authorizedWhenInUse, .authorizedAlways: .allowed
        case .denied, .restricted: .denied
        @unknown default: .notAsked
        }
    }

    static func permission(from status: AVAuthorizationStatus) -> SensorPermission {
        switch status {
        case .notDetermined: .notAsked
        case .authorized: .allowed
        case .denied, .restricted: .denied
        @unknown default: .notAsked
        }
    }

    static func permission(from permission: AVAudioApplication.recordPermission) -> SensorPermission {
        switch permission {
        case .undetermined: .notAsked
        case .granted: .allowed
        case .denied: .denied
        @unknown default: .notAsked
        }
    }

    static func permission(from status: CBManagerAuthorization) -> SensorPermission {
        switch status {
        case .notDetermined: .notAsked
        case .allowedAlways: .allowed
        case .denied, .restricted: .denied
        @unknown default: .notAsked
        }
    }
}
