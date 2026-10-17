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

/// A high tone. A higher gauge reading is a higher pitch and a louder tone.
enum WidgetTone {
    static let lowPitch = 1_600.0
    static let highPitch = 4_200.0
    static let quiet = 0.02
    static let loud = 0.9

    static func pitch(_ fraction: Double) -> Double {
        let level = min(max(fraction, 0), 1)
        return lowPitch * pow(highPitch / lowPitch, level)
    }

    static func volume(_ fraction: Double) -> Double {
        let level = min(max(fraction, 0), 1)
        return quiet * pow(loud / quiet, level)
    }

    static func loop(frequency: Double) -> Data {
        let rate = 44_100
        let tone = min(max(frequency, 200), 8_000)
        let samplesPerCycle = max(2, Int((Double(rate) / tone).rounded()))
        let count = samplesPerCycle * 16
        let actual = Double(rate) / Double(samplesPerCycle)
        var pcm = Data(capacity: count * 2)
        for index in 0..<count {
            let theta = 2 * Double.pi * actual * Double(index) / Double(rate)
            let sample = Int16((sin(theta) * 0.9 * Double(Int16.max)).rounded())
            let bits = UInt16(bitPattern: sample)
            pcm.append(UInt8(truncatingIfNeeded: bits))
            pcm.append(UInt8(truncatingIfNeeded: bits >> 8))
        }
        return DetectionTone.header(sampleRate: rate, pcm: pcm) + pcm
    }
}

/// Plays the featured widget's tone and retargets pitch and loudness as its reading moves.
@MainActor
final class WidgetTonePlayer {
    private var task: Task<Void, Never>?
    private var player: AVAudioPlayer?
    private var preparedPitch = 0.0
    private var level: () -> Double? = { nil }

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

    func stop() {
        task?.cancel()
        task = nil
        level = { nil }
        silence()
    }

    private func render() {
        apply(level())
    }

    private func apply(_ fraction: Double?) {
        guard let fraction else {
            silence()
            return
        }
        let pitch = WidgetTone.pitch(fraction)
        let volume = Float(WidgetTone.volume(fraction))
        prepareSession()
        let pitchChanged = player == nil || abs(preparedPitch - pitch) / max(pitch, 1) > 0.03
        if pitchChanged {
            player?.stop()
            player = try? AVAudioPlayer(data: WidgetTone.loop(frequency: pitch))
            player?.numberOfLoops = -1
            player?.prepareToPlay()
            player?.volume = volume
            preparedPitch = pitch
            if player?.play() != true {
                player = nil
                preparedPitch = 0
            }
        } else {
            player?.volume = volume
        }
    }

    private func silence() {
        player?.stop()
        player = nil
        preparedPitch = 0
    }

    private func prepareSession() {
        let session = AVAudioSession.sharedInstance()
        if session.category == .record {
            try? session.setCategory(.playAndRecord, mode: .measurement, options: [.defaultToSpeaker, .mixWithOthers])
        } else if session.category != .playback && session.category != .playAndRecord {
            try? session.setCategory(.playback, options: [.mixWithOthers])
            try? session.setActive(true)
        }
    }
}
