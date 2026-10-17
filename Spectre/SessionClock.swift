import Foundation

/// A sample's position on the session clock and on the wall clock.
/// Later hits store this pair so replay can show both.
struct SampleTime: Equatable {
    var elapsed: Duration
    var wallTime: Date
}

/// One monotonic clock for a session. Elapsed time is measured from `origin`.
struct SessionClock: Equatable {
    var origin: ContinuousClock.Instant
    var wallClockStart: Date

    func elapsed(at instant: ContinuousClock.Instant) -> Duration {
        instant - origin
    }

    func sampleTime(at instant: ContinuousClock.Instant, wallTime: Date) -> SampleTime {
        SampleTime(elapsed: elapsed(at: instant), wallTime: wallTime)
    }
}

enum ElapsedTimeFormat {
    static func string(for duration: Duration) -> String {
        let parts = duration.components
        let negative = parts.seconds < 0 || (parts.seconds == 0 && parts.attoseconds < 0)
        let seconds = abs(parts.seconds)
        let tenths = abs(parts.attoseconds) / 100_000_000_000_000_000
        let hours = seconds / 3600
        let minutes = (seconds % 3600) / 60
        let secs = seconds % 60
        let body: String
        if hours > 0 {
            body = String(format: "%d:%02d:%02d.%d", hours, minutes, secs, tenths)
        } else {
            body = String(format: "%d:%02d.%d", minutes, secs, tenths)
        }
        return negative ? "-\(body)" : body
    }
}
