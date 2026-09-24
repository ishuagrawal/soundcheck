import AppKit
import SwiftUI

/// A Control Center–style capsule slider. AppKit keeps native keyboard,
/// accessibility, focus and click-to-jump tracking; only drawing changes.
/// Labels are layered on top in SwiftUI with hit testing disabled.
struct VolumeSlider: NSViewRepresentable {
    @Binding var value: Double
    var tint: Color
    var label: String
    var muted = false
    var height: CGFloat = 30

    @Environment(\.isEnabled) private var enabled

    func makeNSView(context: Context) -> NSSlider {
        let slider = NSSlider()
        slider.cell = CapsuleSliderCell()
        slider.minValue = 0; slider.maxValue = 1
        slider.doubleValue = value
        slider.target = context.coordinator
        slider.action = #selector(Coordinator.changed(_:))
        slider.isContinuous = true
        slider.focusRingType = .default
        slider.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return slider
    }

    func updateNSView(_ slider: NSSlider, context: Context) {
        context.coordinator.parent = self
        if abs(slider.doubleValue - value) > 0.0001 { slider.doubleValue = value }
        slider.isEnabled = enabled
        slider.setAccessibilityLabel(label)
        slider.setAccessibilityValueDescription(muted ? "Muted" : "\(Int((value * 100).rounded())) percent")
        if let cell = slider.cell as? CapsuleSliderCell {
            cell.tint = NSColor(tint)
            cell.isMuted = muted
        }
        slider.needsDisplay = true
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSSlider, context: Context) -> CGSize? {
        .init(width: proposal.width ?? 200, height: height)
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    @MainActor final class Coordinator: NSObject {
        var parent: VolumeSlider
        init(_ parent: VolumeSlider) { self.parent = parent }
        @objc func changed(_ sender: NSSlider) { parent.value = sender.doubleValue }
    }
}

/// The knob is as wide as the track is tall and never drawn: the fill simply
/// ends at the knob's trailing edge, so the tracking math and the visible edge
/// agree, and zero volume leaves a small circle, as in Control Center.
private final class CapsuleSliderCell: NSSliderCell {
    var tint: NSColor = .controlAccentColor
    var isMuted = false

    private var bounds: NSRect { controlView?.bounds ?? .zero }
    private var isDark: Bool {
        controlView?.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }

    override var knobThickness: CGFloat { bounds.height }
    override func barRect(flipped: Bool) -> NSRect { bounds }

    override func drawBar(inside rect: NSRect, flipped: Bool) {
        let track = bounds
        let radius = track.height / 2
        let contrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
        NSColor.labelColor.withAlphaComponent(isDark ? 0.09 : 0.065).setFill()
        NSBezierPath(roundedRect: track, xRadius: radius, yRadius: radius).fill()
        if contrast {
            NSColor.labelColor.withAlphaComponent(0.35).setStroke()
            let edge = NSBezierPath(roundedRect: track.insetBy(dx: 0.5, dy: 0.5), xRadius: radius - 0.5, yRadius: radius - 0.5)
            edge.lineWidth = 1; edge.stroke()
        }
        let fraction = CGFloat((doubleValue - minValue) / max(0.001, maxValue - minValue))
        let fill = NSRect(x: track.minX, y: track.minY,
                          width: track.height + (track.width - track.height) * min(1, max(0, fraction)), height: track.height)
        let alpha: CGFloat = !isEnabled ? 0.14 : (isMuted ? 0.12 : (isDark ? 0.46 : 0.3))
        tint.withAlphaComponent(alpha).setFill()
        NSBezierPath(roundedRect: fill, xRadius: radius, yRadius: radius).fill()
    }

    override func drawKnob(_ knobRect: NSRect) {}

    override func drawFocusRingMask(withFrame cellFrame: NSRect, in controlView: NSView) {
        let radius = controlView.bounds.height / 2
        NSBezierPath(roundedRect: controlView.bounds, xRadius: radius, yRadius: radius).fill()
    }

    override func focusRingMaskBounds(forFrame cellFrame: NSRect, in controlView: NSView) -> NSRect { controlView.bounds }
}
