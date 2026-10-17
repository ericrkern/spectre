import AudioToolbox
import AVFoundation
import UIKit

/// Signals a saved detection with a haptic. The featured widget's tone follows its reading.
@MainActor
final class ToneDetectionAlert: DetectionAlerting {
    private var player: AVAudioPlayer?

    func announce() {
        UINotificationFeedbackGenerator().notificationOccurred(.warning)
    }

    func play(_ data: Data) {
        let session = AVAudioSession.sharedInstance()
        if session.category == .record {
            try? session.setCategory(.playAndRecord, mode: .measurement, options: [.defaultToSpeaker, .mixWithOthers])
        } else if session.category != .playback && session.category != .playAndRecord {
            try? session.setCategory(.playback, options: [.mixWithOthers])
            try? session.setActive(true)
        }
        guard let player = try? AVAudioPlayer(data: data) else {
            AudioServicesPlayAlertSound(1005)
            return
        }
        player.prepareToPlay()
        self.player = player
        if !player.play() {
            AudioServicesPlayAlertSound(1005)
        }
    }
}

@MainActor
final class ClipPlayback {
    static let shared = ClipPlayback()
    private let alert = ToneDetectionAlert()

    func play(_ data: Data) {
        alert.play(data)
    }
}

enum GeigerClick {
    static func wavData(frequency: Double) -> Data {
        let rate = 22_050
        let count = rate / 80
        var pcm = Data(capacity: count * 2)
        let tone = min(max(frequency, 80), 4000)
        for index in 0..<count {
            let envelope = exp(-Double(index) / Double(count) * 6)
            let theta = 2 * Double.pi * tone * Double(index) / Double(rate)
            let sample = Int16(sin(theta) * envelope * 0.8 * Double(Int16.max)).littleEndian
            pcm.append(UInt8(truncatingIfNeeded: sample))
            pcm.append(UInt8(truncatingIfNeeded: sample >> 8))
        }
        return DetectionTone.header(sampleRate: rate, pcm: pcm) + pcm
    }
}

enum DetectionTone {
    static func wavData() -> Data {
        let rate = 22_050
        var pcm = Data()
        pcm.append(samples(frequency: 880, rate: rate, seconds: 0.11))
        pcm.append(samples(frequency: 0, rate: rate, seconds: 0.03))
        pcm.append(samples(frequency: 1318, rate: rate, seconds: 0.16))
        return header(sampleRate: rate, pcm: pcm) + pcm
    }

    private static func samples(frequency: Double, rate: Int, seconds: Double) -> Data {
        let count = Int(Double(rate) * seconds)
        var data = Data(capacity: count * 2)
        let fade = max(1, rate / 200)
        for index in 0..<count {
            let envelope: Double
            if index < fade {
                envelope = Double(index) / Double(fade)
            } else if index > count - fade {
                envelope = Double(count - index) / Double(fade)
            } else {
                envelope = 1
            }
            let theta = 2 * Double.pi * frequency * Double(index) / Double(rate)
            let sample = Int16(sin(theta) * envelope * 0.45 * Double(Int16.max)).littleEndian
            data.append(UInt8(truncatingIfNeeded: sample))
            data.append(UInt8(truncatingIfNeeded: sample >> 8))
        }
        return data
    }

    static func header(sampleRate: Int, pcm: Data) -> Data {
        let byteRate = UInt32(sampleRate * 2)
        let chunkSize = UInt32(36 + pcm.count)
        var data = Data()
        data.append(contentsOf: [0x52, 0x49, 0x46, 0x46])
        data.append(little: chunkSize)
        data.append(contentsOf: [0x57, 0x41, 0x56, 0x45])
        data.append(contentsOf: [0x66, 0x6D, 0x74, 0x20])
        data.append(little: UInt32(16))
        data.append(little: UInt16(1))
        data.append(little: UInt16(1))
        data.append(little: UInt32(sampleRate))
        data.append(little: byteRate)
        data.append(little: UInt16(2))
        data.append(little: UInt16(16))
        data.append(contentsOf: [0x64, 0x61, 0x74, 0x61])
        data.append(little: UInt32(pcm.count))
        return data
    }
}

private extension Data {
    mutating func append(little value: UInt32) {
        let little = value.littleEndian
        append(UInt8(truncatingIfNeeded: little))
        append(UInt8(truncatingIfNeeded: little >> 8))
        append(UInt8(truncatingIfNeeded: little >> 16))
        append(UInt8(truncatingIfNeeded: little >> 24))
    }

    mutating func append(little value: UInt16) {
        let little = value.littleEndian
        append(UInt8(truncatingIfNeeded: little))
        append(UInt8(truncatingIfNeeded: little >> 8))
    }
}
