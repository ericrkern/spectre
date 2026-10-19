import AVFoundation
import Foundation

/// The featured widget's gauge, from 0 at the bottom of its scale to 1 at the top.
enum WidgetMetric {
    static func level(_ widget: SensorWidgetState) -> Double? {
        guard widget.status == .live, let reading = widget.reading, reading.isFinite else { return nil }
        switch widget.kind {
        case .deviceMotion: return DialScale.motion(reading)
        case .magnetometer: return DialScale.field(reading)
        case .barometer: return DialScale.pressure(reading)
        case .pedometer: return DialScale.steps(reading)
        case .microphone: return DialScale.sound(reading)
        case .camera: return DialScale.brightness(reading)
        case .lidar, .trueDepth, .ultraWideband: return DialScale.depth(reading)
        case .accelerometer: return DialScale.acceleration(reading)
        case .gyroscope: return DialScale.rotation(reading)
        case .altitude: return DialScale.altitude(reading)
        case .pace: return DialScale.pace(reading)
        case .activity, .proximity, .nfc, .thermal: return DialScale.unit(reading)
        case .nearby: return DialScale.fraction(reading, min: 0, max: 8)
        case .survey: return DialScale.unit(reading)
        case .compass, .location, .bluetooth: return nil
        }
    }
}

/// A low, wavering voice. A higher reading is louder, faster, and more dissonant.
enum WidgetTone {
    static let lowPitch = 140.0
    static let highPitch = 420.0
    static let quiet = 0.0
    static let loud = 0.75

    static func pitch(_ fraction: Double) -> Double {
        let level = min(max(fraction, 0), 1)
        return lowPitch * pow(highPitch / lowPitch, level)
    }

    static func volume(_ fraction: Double) -> Double {
        let level = min(max(fraction, 0), 1)
        return loud * pow(level, 1.4)
    }

    /// Two close tones, a thin upper voice, and a slow tremble. The buffer repeats cleanly.
    static func loop(level: Double) -> Data {
        let rate = 22_050
        let seconds = 2
        let count = rate * seconds
        let activity = min(max(level, 0), 1)
        let fundamental = max(80, pitch(activity).rounded())
        let beat = 2 + (activity * 7).rounded()
        let upper = max(fundamental + 40, (fundamental * (2.4 + activity * 0.9)).rounded())
        let tremoloCycles = 1 + Int((activity * 2).rounded())
        var pcm = Data(capacity: count * 2)
        for index in 0..<count {
            let time = Double(index) / Double(rate)
            let moan = sin(2 * Double.pi * fundamental * time)
            let shadow = sin(2 * Double.pi * (fundamental + beat) * time)
            let air = sin(2 * Double.pi * upper * time)
            let breathGate = sin(Double.pi * time / Double(seconds))
            let breath = breathSample(index) * breathGate
            let tremble = 0.62 + 0.38 * sin(2 * Double.pi * Double(tremoloCycles) * time / Double(seconds))
            let body = moan * 0.52
                + shadow * (0.16 + 0.38 * activity)
                + air * (0.04 + 0.18 * activity)
                + breath * (0.04 + 0.14 * activity)
            let shaped = min(1, max(-1, body * tremble))
            let sample = Int16((shaped * 0.9 * Double(Int16.max)).rounded())
            let bits = UInt16(bitPattern: sample)
            pcm.append(UInt8(truncatingIfNeeded: bits))
            pcm.append(UInt8(truncatingIfNeeded: bits >> 8))
        }
        return DetectionTone.header(sampleRate: rate, pcm: pcm) + pcm
    }

    private static func breathSample(_ index: Int) -> Double {
        var value = UInt32(truncatingIfNeeded: index &* 1_103_515_245 &+ 12_345)
        value ^= value >> 16
        return Double(value % 10_000) / 5_000 - 1
    }
}

/// Rises quickly when a reading or a detection arrives, then takes several seconds to fall quiet.
struct ToneFade {
    static let attackSeconds = 0.4
    static let releaseSeconds = 8.0
    var level = 0.0

    mutating func advance(toward target: Double, seconds: Double) -> Double {
        let goal = min(max(target, 0), 1)
        let step = max(seconds, 0)
        guard step > 0 else { return level }
        let tau = goal >= level ? Self.attackSeconds : Self.releaseSeconds
        let alpha = 1 - exp(-step / tau)
        level += (goal - level) * alpha
        if level < 0.0005 {
            level = 0
        }
        return level
    }

    mutating func stir() {
        level = 1
    }
}

/// Plays the featured widget's voice. A detection opens it fully. Quiet readings let it fade.
@MainActor
final class WidgetTonePlayer {
    private var task: Task<Void, Never>?
    private var player: AVAudioPlayer?
    private var preparedLevel = -1.0
    private var fade = ToneFade()
    private var level: () -> Double? = { nil }
    private var sessionReady = false
    private var activating = false

    func start(level: @escaping () -> Double?) {
        self.level = level
        guard task == nil else { return }
        task = Task { [weak self] in
            while !Task.isCancelled {
                self?.render()
                try? await Task.sleep(for: .milliseconds(40))
            }
        }
    }

    func stir() {
        fade.stir()
    }

    func stop() {
        task?.cancel()
        task = nil
        level = { nil }
        fade = ToneFade()
        activating = false
        silence()
    }

    private func render() {
        apply(level())
    }

    private func apply(_ fraction: Double?) {
        let heard = fade.advance(toward: fraction ?? 0, seconds: 0.04)
        guard heard >= 0.02 else {
            silence()
            return
        }
        let volume = Float(WidgetTone.volume(heard))
        guard ensureSession() else { return }
        let timbreChanged = player == nil || abs(preparedLevel - heard) > 0.08
        if timbreChanged {
            player?.stop()
            player = try? AVAudioPlayer(data: WidgetTone.loop(level: heard))
            player?.numberOfLoops = -1
            player?.volume = volume
            preparedLevel = heard
            if player?.play() != true {
                player = nil
                preparedLevel = -1
            }
        } else {
            player?.volume = volume
        }
    }

    private func silence() {
        player?.stop()
        player = nil
        preparedLevel = -1
    }

    /// Returns once the session is already active. Activation itself stays off the main thread.
    private func ensureSession() -> Bool {
        let session = AVAudioSession.sharedInstance()
        if session.category == .record {
            try? session.setCategory(.playAndRecord, mode: .measurement, options: [.defaultToSpeaker, .mixWithOthers])
        } else if session.category != .playback && session.category != .playAndRecord {
            try? session.setCategory(.playback, options: [.mixWithOthers])
        }
        if sessionReady { return true }
        guard !activating else { return false }
        activating = true
        let finished: @Sendable (Bool) -> Void = { [weak self] activated in
            Task { @MainActor in
                self?.activating = false
                self?.sessionReady = activated
            }
        }
        if #available(iOS 27.0, *) {
            session.activate(options: []) { activated, _ in
                finished(activated)
            }
        } else {
            DispatchQueue.global(qos: .userInitiated).async {
                let activated = (try? session.setActive(true)) != nil
                finished(activated)
            }
        }
        return false
    }
}
