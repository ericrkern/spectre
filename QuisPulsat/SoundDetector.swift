import Foundation

struct SoundFrame: Equatable, Sendable {
    var timestamp: TimeInterval
    var sampleRate: Double
    var samples: [Float]
}

enum SoundPhase: Equatable, Sendable {
    case waiting
    case learning(startedAt: TimeInterval)
    case watching
}

/// Learns the room's sound, then flags a transient peak or a sustained narrow tone.
/// A peak and a tone stay separate hits. Each hit keeps a short playable clip.
struct SoundDetector: Equatable {
    var sensitivity = DetectionSensitivity.standard
    private(set) var phase: SoundPhase = .waiting
    private var rmsHistory: [Double] = []
    private var peakHistory: [Double] = []
    private var baselineRMS = -80.0
    private var baselinePeak = -80.0
    private var recentPeaks: [Double] = []
    private var recentLevels: [Double] = []
    private var toneSince: TimeInterval?
    private var toneHertz = 0.0
    private var cooldownUntil: [String: TimeInterval] = [:]
    private var clip: [Float] = []
    private var clipRate = 48_000.0

    static let learningText = "Learning the room's sound."
    static let watchingText = "Listening for peaks and narrow tones."

    var statusText: String {
        switch phase {
        case .waiting: ""
        case .learning: Self.learningText
        case .watching: Self.watchingText
        }
    }

    mutating func noteInterruption() {
        phase = .waiting
        rmsHistory = []
        peakHistory = []
        recentPeaks = []
        recentLevels = []
        toneSince = nil
        cooldownUntil = [:]
        clip = []
    }

    mutating func ingest(_ frame: SoundFrame) -> [LeadHit] {
        guard frame.sampleRate > 0, !frame.samples.isEmpty else { return [] }
        remember(frame)
        let level = SignalMeasure.levels(frame.samples)
        switch phase {
        case .waiting:
            phase = .learning(startedAt: frame.timestamp)
            rmsHistory = [level.rms]
            peakHistory = [level.peak]
            return []
        case .learning(let startedAt):
            rmsHistory.append(level.rms)
            peakHistory.append(level.peak)
            if frame.timestamp - startedAt >= DetectionLimit.soundBaseline {
                baselineRMS = SignalMeasure.median(rmsHistory)
                baselinePeak = SignalMeasure.median(peakHistory)
                phase = .watching
            }
            return []
        case .watching:
            recentPeaks = remember(level.peak, in: recentPeaks)
            recentLevels = remember(level.rms, in: recentLevels)
            return detect(frame, level: level)
        }
    }

    private mutating func detect(_ frame: SoundFrame, level: (rms: Double, peak: Double)) -> [LeadHit] {
        var hits: [LeadHit] = []
        let crest = level.peak - level.rms
        let transient = SignalMeasure.transientFraction(frame.samples) < 0.04
        let peakRise = sensitivity.scaled(DetectionLimit.soundPeakRise)
        if crest >= 12, transient, level.peak >= baselinePeak + peakRise {
            hits.append(contentsOf: emit(
                feature: "Level peak",
                magnitude: level.peak,
                threshold: baselinePeak + peakRise,
                timestamp: frame.timestamp,
                detail: nil,
                samples: recentPeaks
            ))
        }

        let toneRise = sensitivity.scaled(DetectionLimit.soundToneRise)
        if let tone = Spectrum.dominantTone(samples: frame.samples, sampleRate: frame.sampleRate),
           tone.share >= sensitivity.scaledShare(DetectionLimit.soundToneShare),
           level.rms >= baselineRMS + toneRise {
            if toneSince == nil || abs(tone.hertz - toneHertz) > 40 {
                toneSince = frame.timestamp
                toneHertz = tone.hertz
            }
            if let toneSince, frame.timestamp - toneSince >= DetectionLimit.soundToneHold {
                hits.append(contentsOf: emit(
                    feature: "Narrow tone",
                    magnitude: level.rms,
                    threshold: baselineRMS + toneRise,
                    timestamp: frame.timestamp,
                    detail: "\(Int(tone.hertz.rounded())) Hz",
                    samples: recentLevels
                ))
                self.toneSince = nil
            }
        } else {
            toneSince = nil
        }
        return hits
    }

    private mutating func emit(
        feature: String,
        magnitude: Double,
        threshold: Double,
        timestamp: TimeInterval,
        detail: String?,
        samples: [Double]
    ) -> [LeadHit] {
        if let until = cooldownUntil[feature], timestamp < until {
            return []
        }
        cooldownUntil[feature] = timestamp + 6
        return [
            LeadHit(
                id: UUID(),
                kind: .sound,
                feature: feature,
                magnitude: magnitude,
                threshold: threshold,
                timestamp: timestamp,
                samples: samples,
                detail: detail,
                clipWAV: WAVEncoder.pcm16(samples: clip, sampleRate: clipRate)
            ),
        ]
    }

    private mutating func remember(_ frame: SoundFrame) {
        clipRate = frame.sampleRate
        clip.append(contentsOf: frame.samples)
        let limit = Int(frame.sampleRate * 0.8)
        if clip.count > limit {
            clip.removeFirst(clip.count - limit)
        }
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

enum SignalMeasure {
    static func levels(_ samples: [Float]) -> (rms: Double, peak: Double) {
        var sum = 0.0
        var peak = 0.0
        for sample in samples {
            let value = Double(sample)
            sum += value * value
            peak = max(peak, abs(value))
        }
        let mean = sum / Double(max(samples.count, 1))
        return (decibels(mean.squareRoot()), decibels(peak))
    }

    static func transientFraction(_ samples: [Float]) -> Double {
        var peak = 0.0
        for sample in samples {
            peak = max(peak, abs(Double(sample)))
        }
        guard peak > 0 else { return 1 }
        let hot = samples.reduce(0) { count, sample in
            count + (abs(Double(sample)) >= peak * 0.5 ? 1 : 0)
        }
        return Double(hot) / Double(samples.count)
    }

    static func median(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return -80 }
        let sorted = values.sorted()
        let middle = sorted.count / 2
        if sorted.count.isMultiple(of: 2) {
            return (sorted[middle - 1] + sorted[middle]) / 2
        }
        return sorted[middle]
    }

    private static func decibels(_ amplitude: Double) -> Double {
        20 * log10(max(amplitude, 1e-7))
    }
}

enum Spectrum {
    static let lowHertz = 20.0
    static let highHertz = 20_000.0
    static let bandCount = 32

    static func rangeLabel(sampleRate: Double) -> String {
        let high = min(highHertz, sampleRate / 2)
        return "20 Hz – \(hertzLabel(high))"
    }

    static func hertzLabel(_ hertz: Double) -> String {
        if hertz >= 1_000 {
            let kilo = hertz / 1_000
            if abs(kilo.rounded() - kilo) < 0.05 {
                return "\(Int(kilo.rounded())) kHz"
            }
            return String(format: "%.1f kHz", kilo)
        }
        return "\(Int(hertz.rounded())) Hz"
    }

    /// Log-spaced band levels from 20 Hz to 20 kHz, or to Nyquist when the capture is slower.
    /// Each level is 0 at 48 dB below the loudest band and 1 at that peak.
    static func levels(samples: [Float], sampleRate: Double, count: Int = bandCount) -> [Double] {
        let empty = [Double](repeating: 0, count: count)
        guard let bins = binPowers(samples: samples, sampleRate: sampleRate), count > 0 else { return empty }
        let high = min(highHertz, sampleRate / 2)
        guard high > lowHertz else { return empty }
        var powers = [Double](repeating: 0, count: count)
        let span = log(high / lowHertz)
        for index in 1..<(bins.n / 2) {
            let hertz = Double(index) * sampleRate / Double(bins.n)
            guard hertz >= lowHertz, hertz <= high else { continue }
            let position = log(hertz / lowHertz) / span
            let band = min(count - 1, Int(position * Double(count)))
            powers[band] += bins.powers[index]
        }
        let peak = powers.max() ?? 0
        guard peak > 1e-12 else { return empty }
        return powers.map { power in
            let decibels = 10 * log10(max(power, peak * 1e-8) / peak)
            return DialScale.fraction(decibels, min: -48, max: 0)
        }
    }

    static func dominantTone(samples: [Float], sampleRate: Double) -> (hertz: Double, share: Double)? {
        guard let bins = binPowers(samples: samples, sampleRate: sampleRate) else { return nil }
        let ceiling = min(highHertz, sampleRate / 2)
        var bestIndex = 0
        var bestPower = 0.0
        var total = 0.0
        for index in 1..<(bins.n / 2) {
            let hertz = Double(index) * sampleRate / Double(bins.n)
            guard hertz >= lowHertz, hertz <= ceiling else { continue }
            let power = bins.powers[index]
            total += power
            if power > bestPower {
                bestPower = power
                bestIndex = index
            }
        }
        guard total > 0 else { return nil }
        return (Double(bestIndex) * sampleRate / Double(bins.n), bestPower / total)
    }

    private static func binPowers(samples: [Float], sampleRate: Double) -> (powers: [Double], n: Int)? {
        let n = largestPowerOfTwo(atMost: samples.count)
        guard n >= 128, sampleRate > 0 else { return nil }
        var real = [Double](repeating: 0, count: n)
        var imaginary = [Double](repeating: 0, count: n)
        let scale = Double(max(n - 1, 1))
        for index in 0..<n {
            let window = 0.5 * (1 - cos(2 * Double.pi * Double(index) / scale))
            real[index] = Double(samples[index]) * window
        }
        transform(&real, &imaginary)
        var powers = [Double](repeating: 0, count: n / 2)
        for index in 1..<(n / 2) {
            powers[index] = real[index] * real[index] + imaginary[index] * imaginary[index]
        }
        return (powers, n)
    }

    private static func largestPowerOfTwo(atMost count: Int) -> Int {
        var n = 1
        while n * 2 <= count {
            n *= 2
        }
        return n
    }

    private static func transform(_ real: inout [Double], _ imaginary: inout [Double]) {
        let count = real.count
        var j = 0
        for index in 1..<count {
            var bit = count >> 1
            while j & bit != 0 {
                j ^= bit
                bit >>= 1
            }
            j ^= bit
            if index < j {
                real.swapAt(index, j)
                imaginary.swapAt(index, j)
            }
        }
        var length = 2
        while length <= count {
            let angle = -2 * Double.pi / Double(length)
            let stepReal = cos(angle)
            let stepImaginary = sin(angle)
            var start = 0
            while start < count {
                var turnReal = 1.0
                var turnImaginary = 0.0
                for offset in 0..<(length / 2) {
                    let evenReal = real[start + offset]
                    let evenImaginary = imaginary[start + offset]
                    let oddIndex = start + offset + length / 2
                    let oddReal = real[oddIndex] * turnReal - imaginary[oddIndex] * turnImaginary
                    let oddImaginary = real[oddIndex] * turnImaginary + imaginary[oddIndex] * turnReal
                    real[start + offset] = evenReal + oddReal
                    imaginary[start + offset] = evenImaginary + oddImaginary
                    real[oddIndex] = evenReal - oddReal
                    imaginary[oddIndex] = evenImaginary - oddImaginary
                    let nextReal = turnReal * stepReal - turnImaginary * stepImaginary
                    turnImaginary = turnReal * stepImaginary + turnImaginary * stepReal
                    turnReal = nextReal
                }
                start += length
            }
            length <<= 1
        }
    }
}

enum WAVEncoder {
    static func pcm16(samples: [Float], sampleRate: Double) -> Data {
        var pcm = Data(capacity: samples.count * 2)
        for sample in samples {
            let clamped = min(1, max(-1, sample))
            let value = Int16((Double(clamped) * 32_767).rounded())
            let bits = UInt16(bitPattern: value)
            pcm.append(UInt8(truncatingIfNeeded: bits))
            pcm.append(UInt8(truncatingIfNeeded: bits >> 8))
        }
        let rate = UInt32(sampleRate.rounded())
        let chunkSize = UInt32(36 + pcm.count)
        var data = Data()
        data.append(contentsOf: [0x52, 0x49, 0x46, 0x46])
        data.append(little: chunkSize)
        data.append(contentsOf: [0x57, 0x41, 0x56, 0x45, 0x66, 0x6D, 0x74, 0x20])
        data.append(little: UInt32(16))
        data.append(little: UInt16(1))
        data.append(little: UInt16(1))
        data.append(little: rate)
        data.append(little: rate * 2)
        data.append(little: UInt16(2))
        data.append(little: UInt16(16))
        data.append(contentsOf: [0x64, 0x61, 0x74, 0x61])
        data.append(little: UInt32(pcm.count))
        return data + pcm
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
