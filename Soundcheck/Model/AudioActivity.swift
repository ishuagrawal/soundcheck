import Foundation

struct AudioReading: Sendable {
    var peak: Float = 0
    var trace = [Float](repeating: 0, count: 64)
    init() {}
    init(peak: Float, state: OpaquePointer?) {
        self.peak = peak
        if let state { SoundcheckRenderReadTrace(state, &trace, UInt32(trace.count)) }
    }
}

/// A short measured amplitude history, not a simulated equalizer or spectrum.
struct AudioActivity {
    static let interval = 1.0 / 24
    static let capacity = 36
    private(set) var samples = [Float](repeating: 0, count: capacity)
    private(set) var timestamp = Date.timeIntervalSinceReferenceDate
    private(set) var level: Float = 0
    private(set) var trace = [Float](repeating: 0, count: 64)
    private(set) var previousTrace = [Float](repeating: 0, count: 64)

    var hasHistory: Bool { samples.contains { $0 > 0 } }
    var isAudible: Bool { samples.suffix(6).contains { $0 > 0.015 } }

    mutating func append(peak: Float, trace pcm: [Float] = [], at time: TimeInterval = Date.timeIntervalSinceReferenceDate) {
        let normalized: Float = peak.isFinite && peak > 0.001
            ? min(1, max(0, (20 * log10(peak) + 60) / 60)) : 0
        // Fast attack and a gentle release keep short transients legible without flicker.
        level += (normalized - level) * (normalized > level ? 0.86 : 0.36)
        if level < 0.005 { level = 0 }
        samples.removeFirst()
        samples.append(level)
        previousTrace = trace
        let divisor = max(0.08, pcm.filter(\.isFinite).map { abs($0) }.max() ?? 0)
        trace = (0..<64).map { index in
            guard index < pcm.count, pcm[index].isFinite, normalized > 0 else { return 0 }
            return min(1, max(-1, pcm[index] / divisor)) * min(1, sqrt(max(0, peak)) * 2.4)
        }
        timestamp = time
    }
}
