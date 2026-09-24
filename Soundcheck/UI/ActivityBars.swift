import SwiftUI

/// A Voice Memos–style level history: rounded bars of the app's measured level
/// that scroll right to left, settling into dots during silence. Heights come
/// from real meter readings; nothing is simulated.
struct ActivityBars: View {
    let activity: AudioActivity
    let color: Color
    var paused = false
    /// Enough bars to show the whole 1.5 s history the meter keeps.
    static let bars = 19
    private static let barWidth: CGFloat = 2
    private static let gap: CGFloat = 2.5
    static var width: CGFloat { CGFloat(bars) * (barWidth + gap) - gap }
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60, paused: paused || reduceMotion)) { timeline in
            Canvas { context, size in
                let step = Self.barWidth + Self.gap
                let samples = activity.samples
                // The newest reading slides in from the right over one meter interval.
                let elapsed = (timeline.date.timeIntervalSinceReferenceDate - activity.timestamp) / AudioActivity.interval
                let slide = reduceMotion ? 0 : (1 - CGFloat(min(1, max(0, elapsed)))) * step
                let visible = Self.bars + 1
                let window = samples.suffix(visible).map { CGFloat($0) }
                // Range from the whole 1.5 s history, so bars don't rescale as each one scrolls away.
                let low = samples.min().map(CGFloat.init) ?? 0, high = samples.max().map(CGFloat.init) ?? 0
                for (index, value) in window.enumerated() {
                    // Readings are dB-scaled 0…1, so music sits in a narrow band. Loudness sets the
                    // overall size; the position within what's on screen sets the shape.
                    let loudness = max(0, (value - 0.2) / 0.8)
                    let shape = high - low > 0.02 ? (value - low) / (high - low) : 1
                    let height = max(Self.barWidth, loudness * (0.3 + 0.7 * shape) * size.height)
                    let x = size.width - Self.barWidth - CGFloat(window.count - 1 - index) * step + slide
                    let bar = CGRect(x: x, y: (size.height - height) / 2, width: Self.barWidth, height: height)
                    context.fill(Path(roundedRect: bar, cornerRadius: Self.barWidth / 2), with: .color(color))
                }
            }
        }
        .frame(width: Self.width)
        .mask(LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.2)],
                             startPoint: .leading, endPoint: .trailing))
        .accessibilityHidden(true)
    }
}
