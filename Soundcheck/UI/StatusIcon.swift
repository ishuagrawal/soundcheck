import AppKit

/// The menu bar glyph: knobless capsule faders, the same shape as the panel's
/// sliders and the app icon. It is a template image, so alpha alone separates
/// track from fill and the system handles tinting.
///
/// The silhouette never changes, so the glyph always reads as Soundcheck. State is
/// carried only by dimming (paused or not yet enabled) and by the fills
/// dropping to the 0% dot when the output is muted.
enum StatusIcon {
    static let brandLevels: [CGFloat] = [0.72, 0.28, 0.88]

    struct State: Equatable {
        var levels: [CGFloat]
        var dimmed = false
        var summary: String

        @MainActor init(model: MixerModel) {
            guard model.enabled else {
                levels = StatusIcon.brandLevels; dimmed = true; summary = "Set up app volume"; return
            }
            guard !model.isBypassed else {
                levels = StatusIcon.brandLevels; dimmed = true; summary = "Controls paused"; return
            }
            levels = model.outputMuted ? StatusIcon.brandLevels.map { _ in 0 } : StatusIcon.brandLevels
            summary = model.outputMuted ? "Output muted" : model.status
        }
    }

    static func image(_ levels: [CGFloat], description: String) -> NSImage {
        let image = NSImage(size: .init(width: 18, height: 18), flipped: false) { rect in
            let width: CGFloat = 4, height: CGFloat = 14, gap: CGFloat = 2.5
            let total = CGFloat(levels.count) * width + CGFloat(levels.count - 1) * gap
            var x = rect.midX - total / 2
            let y = rect.midY - height / 2
            for level in levels {
                let track = NSRect(x: x, y: y, width: width, height: height)
                NSColor.black.withAlphaComponent(0.3).setFill()
                NSBezierPath(roundedRect: track, xRadius: width / 2, yRadius: width / 2).fill()
                let fill = NSRect(x: x, y: y, width: width, height: width + (height - width) * min(1, max(0, level)))
                NSColor.black.setFill()
                NSBezierPath(roundedRect: fill, xRadius: width / 2, yRadius: width / 2).fill()
                x += width + gap
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = description
        return image
    }
}

/// Keeps the status button's glyph in step with the model, tweening between
/// states so the fills slide rather than jump.
@MainActor
final class StatusIconController {
    private let model: MixerModel
    private weak var button: NSStatusBarButton?
    private var shown = StatusIcon.brandLevels
    private var from: [CGFloat] = []
    private var target: [CGFloat] = []
    private var state: StatusIcon.State?
    private var start: CFTimeInterval = 0
    private var timer: Timer?
    private static let duration: CFTimeInterval = 0.28

    init(model: MixerModel, button: NSStatusBarButton) {
        self.model = model
        self.button = button
        observe()
    }

    private func observe() {
        let next = withObservationTracking { StatusIcon.State(model: model) } onChange: { [weak self] in
            Task { @MainActor in self?.observe() }
        }
        apply(next)
    }

    private func apply(_ next: StatusIcon.State) {
        guard next != state, let button else { return }
        let first = state == nil
        state = next
        let label = "Soundcheck — \(next.summary)"
        button.toolTip = label
        button.setAccessibilityLabel(label)
        button.appearsDisabled = next.dimmed
        target = next.levels
        guard !first, target != shown, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            timer?.invalidate(); timer = nil
            draw(target)
            return
        }
        from = shown
        start = CACurrentMediaTime()
        if timer == nil {
            let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.step() }
            }
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
        }
        step()
    }

    private func step() {
        let t = min(1, (CACurrentMediaTime() - start) / Self.duration)
        let eased = CGFloat(t < 0.5 ? 4 * t * t * t : 1 - pow(-2 * t + 2, 3) / 2)
        draw(zip(from, target).map { a, b in a + (b - a) * eased })
        if t >= 1 { timer?.invalidate(); timer = nil }
    }

    private func draw(_ levels: [CGFloat]) {
        shown = levels
        button?.image = StatusIcon.image(levels, description: state.map { "Soundcheck — \($0.summary)" } ?? "Soundcheck — app volume")
    }
}
