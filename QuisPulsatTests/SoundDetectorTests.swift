import AVFoundation
import Foundation
import Testing
@testable import QuisPulsat

private let rate = 8_000.0
private let count = 512
private var hop: Double { Double(count) / rate }

private func multiTone(amplitude: Float, at timestamp: TimeInterval) -> SoundFrame {
    var samples = [Float](repeating: 0, count: count)
    for index in 0..<count {
        let time = Double(index) / rate
        var value = 0.0
        for partial in 0..<8 {
            let hertz = 320.0 + Double(partial) * 320.0
            value += sin(2 * Double.pi * hertz * time)
        }
        samples[index] = Float(value / 8) * amplitude
    }
    return SoundFrame(timestamp: timestamp, sampleRate: rate, samples: samples)
}

private func sine(hertz: Double, amplitude: Float, at timestamp: TimeInterval) -> SoundFrame {
    var samples = [Float](repeating: 0, count: count)
    for index in 0..<count {
        let time = Double(index) / rate
        samples[index] = Float(sin(2 * Double.pi * hertz * time) * Double(amplitude))
    }
    return SoundFrame(timestamp: timestamp, sampleRate: rate, samples: samples)
}

private func clap(at timestamp: TimeInterval) -> SoundFrame {
    var frame = multiTone(amplitude: 0.02, at: timestamp)
    for index in 200..<204 {
        frame.samples[index] = 0.95
    }
    return frame
}

private func learn(_ detector: inout SoundDetector, amplitude: Float = 0.02) {
    var timestamp = 0.0
    while timestamp < DetectionLimit.soundBaseline {
        _ = detector.ingest(multiTone(amplitude: amplitude, at: timestamp))
        timestamp += hop
    }
    _ = detector.ingest(multiTone(amplitude: amplitude, at: DetectionLimit.soundBaseline))
}

@Test func aPureToneDominatesItsSpectrum() {
    let tone = Spectrum.dominantTone(samples: sine(hertz: 1000, amplitude: 0.2, at: 0).samples, sampleRate: rate)
    #expect(tone != nil)
    #expect(abs((tone?.hertz ?? 0) - 1000) < 20)
    #expect((tone?.share ?? 0) > 0.5)
}

@Test func theMicrophoneSpectrumSpansTheCaptureAndRisesWithPitch() {
    #expect(Spectrum.rangeLabel(sampleRate: 48_000) == "20 Hz – 20 kHz")
    let low = Spectrum.levels(samples: tone(hertz: 200, sampleRate: 48_000, count: 8_192), sampleRate: 48_000)
    let high = Spectrum.levels(samples: tone(hertz: 8_000, sampleRate: 48_000, count: 8_192), sampleRate: 48_000)
    #expect(low.count == Spectrum.bandCount)
    #expect(high.count == Spectrum.bandCount)
    let lowPeak = low.firstIndex(of: low.max() ?? 0) ?? 0
    let highPeak = high.firstIndex(of: high.max() ?? 0) ?? 0
    #expect(highPeak > lowPeak)
    #expect((low.max() ?? 0) > 0.9)
    #expect((high.max() ?? 0) > 0.9)
}

private func tone(hertz: Double, sampleRate: Double, count: Int) -> [Float] {
    (0..<count).map { index in
        Float(sin(2 * Double.pi * hertz * Double(index) / sampleRate))
    }
}

@Test func speechBandNoiseDoesNotRetriggerAfterTheBaseline() {
    var detector = SoundDetector()
    learn(&detector, amplitude: 0.08)
    #expect(detector.phase == .watching)
    var hits: [LeadHit] = []
    var timestamp = DetectionLimit.soundBaseline + hop
    while timestamp < 8 {
        hits.append(contentsOf: detector.ingest(multiTone(amplitude: 0.08, at: timestamp)))
        timestamp += hop
    }
    #expect(hits.isEmpty)
}

@Test func aClapAfterAQuietRoomIsAPeakWithPlayableAudio() throws {
    var detector = SoundDetector()
    learn(&detector)
    let hits = detector.ingest(clap(at: DetectionLimit.soundBaseline + hop))
    #expect(hits.map(\.feature) == ["Level peak"])
    #expect(hits[0].kind == .sound)
    #expect(hits[0].magnitude >= hits[0].threshold)
    let clip = try #require(hits[0].clipWAV)
    #expect(clip.prefix(4) == Data([0x52, 0x49, 0x46, 0x46]))
    let player = try AVAudioPlayer(data: clip)
    #expect(player.duration > 0.2)
    #expect(player.duration <= 0.85)
}

@Test func aSustainedToneIsItsOwnHitAndDoesNotRepeatImmediately() {
    var detector = SoundDetector()
    learn(&detector)
    var hits: [LeadHit] = []
    var timestamp = DetectionLimit.soundBaseline + hop
    let end = timestamp + 1.2
    while timestamp < end {
        hits.append(contentsOf: detector.ingest(sine(hertz: 1000, amplitude: 0.2, at: timestamp)))
        timestamp += hop
    }
    #expect(hits.map(\.feature) == ["Narrow tone"])
    #expect(hits[0].detail == "1000 Hz")
    #expect(hits[0].magnitudeLabel.contains("1000 Hz"))
    #expect(hits[0].clipWAV != nil)
}

@MainActor
@Test func aSoundHitSavesItsClip() {
    let feed = SensorFeed(widgets: [
        SensorWidgetState(kind: .microphone, status: .live, value: "-12 dB"),
    ])
    let detections = MemoryDetectionStore()
    let alert = CountingDetectionAlert()
    let controller = DashboardController(
        feed: feed,
        store: MemoryCaptureStore(),
        detections: detections,
        alert: alert
    )
    let clip = WAVEncoder.pcm16(samples: [0, 0.2, -0.2, 0], sampleRate: 8_000)
    let hit = LeadHit(
        id: UUID(),
        kind: .sound,
        feature: "Level peak",
        magnitude: -6,
        threshold: -20,
        timestamp: 6,
        samples: [-40, -6],
        clipWAV: clip
    )
    controller.record([hit])
    #expect(alert.announcements == 1)
    #expect(detections.detections[0].clipWAV == clip)
    #expect(detections.detections[0].magnitudeLabel == "-6 dB")
    #expect(detections.detections[0].title == "Sound")
}
