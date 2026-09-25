import AppKit
import SwiftUI

/// A single native Liquid Glass surface, anchored to the status item. No Dock,
/// document window, extra blur layer, or private popover-background overrides.
@MainActor
final class MenuBarPanelController: NSObject, NSWindowDelegate {
    private let model: MixerModel
    private let panel = MixerPanel(contentRect: .init(x: 0, y: 0, width: MixerView.width, height: 400),
                                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    private weak var button: NSStatusBarButton?
    private var outsideMonitor: Any?
    private var lastHidden: CFTimeInterval = 0
    private var size = CGSize(width: MixerView.width, height: 400)
    private var resizeLink: CADisplayLink?
    private var resizeFrom = NSRect.zero
    private var resizeTo = NSRect.zero
    private var resizeStart: CFTimeInterval = 0

    init(model: MixerModel, button: NSStatusBarButton?) {
        self.model = model
        self.button = button
        super.init()
        panel.delegate = self
        panel.isOpaque = false
        panel.backgroundColor = .clear
        // The window server's shadow for a borderless, non-opaque window adds a hard
        // dark rim around the rounded glass that shows on light backgrounds, so the
        // shadow is drawn in-window instead (see `GlassContainerView`).
        panel.hasShadow = false
        panel.level = .popUpMenu
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.transient, .moveToActiveSpace, .fullScreenAuxiliary]
        panel.title = "Soundcheck"
        panel.setAccessibilityLabel("Soundcheck app volume mixer")
        panel.onEscape = { [weak self] in self?.hide() }
        let host = NSHostingView(rootView: MixerView(model: model, onSizeChange: { [weak self] size in
            // AppKit window changes must occur after SwiftUI's current layout pass.
            DispatchQueue.main.async { self?.resize(to: size) }
        }))
        host.sizingOptions = []
        let container = GlassContainerView(insets: Self.shadowInsets)
        container.onClickOutsideGlass = { [weak self] in self?.hide() }
        let glass = container.glass
        glass.contentView = host
        host.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: glass.leadingAnchor),
            host.trailingAnchor.constraint(equalTo: glass.trailingAnchor),
            host.topAnchor.constraint(equalTo: glass.topAnchor),
            host.bottomAnchor.constraint(equalTo: glass.bottomAnchor)
        ])
        panel.contentView = container
    }

    /// Room around the glass for its shadow, which falls mostly downward.
    private static let shadowInsets = NSEdgeInsets(top: 12, left: 24, bottom: 34, right: 24)

    var isVisible: Bool { panel.isVisible }
    /// Clicking the status item while the panel is open first makes the panel resign
    /// key, which hides it, and only then runs the button's action. That click closed
    /// the panel, so it must not reopen it.
    func toggle() {
        if isVisible { hide() } else if CACurrentMediaTime() - lastHidden > 0.3 { show() }
    }

    func show() {
        position()
        // A non-activating panel becomes key without activating Soundcheck. macOS doesn't
        // reliably grant an accessory app's activation request from a status item
        // click, so the panel would otherwise open in its inactive look and switch
        // to the active one on the first click inside.
        let appearing = !panel.isVisible
        if appearing { panel.alphaValue = 0 }
        panel.makeKeyAndOrderFront(nil)
        if appearing {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.14
                context.timingFunction = .init(name: .easeOut)
                panel.animator().alphaValue = 1
            }
        }
        button?.highlight(true)
        model.setPanelVisible(true)
        if outsideMonitor == nil {
            outsideMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
                Task { @MainActor in self?.hide() }
            }
        }
    }

    func hide() {
        if panel.isVisible { lastHidden = CACurrentMediaTime() }
        panel.orderOut(nil)
        button?.highlight(false)
        if let outsideMonitor { NSEvent.removeMonitor(outsideMonitor); self.outsideMonitor = nil }
        if model.isPanelVisible { model.setPanelVisible(false) }
    }

    func windowDidResignKey(_ notification: Notification) { hide() }
    func windowDidBecomeKey(_ notification: Notification) {
        if !model.isPanelVisible { model.setPanelVisible(true) }
    }

    private func resize(to proposed: CGSize) {
        guard proposed.width > 0, proposed.height > 0,
              abs(proposed.height - size.height) > 0.5 || abs(proposed.width - size.width) > 0.5 else { return }
        size = proposed
        position(animated: panel.isVisible && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
    }

    /// Keeps the glass's top edge under the menu bar. The display link resizes the
    /// visible panel so its in-window shadow follows the changing frame.
    private func position(animated: Bool = false) {
        guard let button, let window = button.window else { return }
        let anchor = window.convertToScreen(button.convert(button.bounds, to: nil))
        let screen = window.screen ?? NSScreen.main
        let visible = screen?.visibleFrame ?? .init(x: 0, y: 0, width: 1440, height: 900)
        let x = min(visible.maxX - size.width - 10, max(visible.minX + 10, anchor.maxX - size.width + 12))
        let top = min(anchor.minY - 7, visible.maxY - 7)
        let glass = NSRect(x: x, y: max(visible.minY + 8, top - size.height), width: size.width, height: size.height)
        let insets = Self.shadowInsets
        let frame = NSRect(x: glass.minX - insets.left, y: glass.minY - insets.bottom,
                           width: glass.width + insets.left + insets.right, height: glass.height + insets.top + insets.bottom)
        guard animated, let view = panel.contentView else {
            resizeLink?.invalidate(); resizeLink = nil
            panel.setFrame(frame, display: true)
            return
        }
        resizeFrom = panel.frame
        resizeTo = frame
        resizeStart = CACurrentMediaTime()
        if resizeLink == nil {
            let link = view.displayLink(target: self, selector: #selector(stepResize(_:)))
            link.add(to: .main, forMode: .common)
            resizeLink = link
        }
    }

    @objc private func stepResize(_ link: CADisplayLink) {
        let t = min(1, max(0, (link.targetTimestamp - resizeStart) / MixerView.resizeDuration))
        let e = Self.easeInOut(t)
        func mix(_ a: CGFloat, _ b: CGFloat) -> CGFloat { (a + (b - a) * e).rounded() }
        let frame = NSRect(x: mix(resizeFrom.minX, resizeTo.minX), y: mix(resizeFrom.minY, resizeTo.minY),
                           width: mix(resizeFrom.width, resizeTo.width), height: mix(resizeFrom.height, resizeTo.height))
        panel.setFrame(t >= 1 ? resizeTo : frame, display: true)
        if t >= 1 { link.invalidate(); resizeLink = nil }
    }

    /// The cubic Bézier (0.42, 0, 0.58, 1) that `MixerView` animates with.
    private static func easeInOut(_ t: Double) -> Double {
        func curve(_ s: Double, _ p1: Double, _ p2: Double) -> Double {
            3 * (1 - s) * (1 - s) * s * p1 + 3 * (1 - s) * s * s * p2 + s * s * s
        }
        var s = t
        for _ in 0..<8 {
            let slope = 3 * (1 - s) * (1 - s) * 0.42 + 6 * (1 - s) * s * (0.58 - 0.42) + 3 * s * s * (1 - 0.58)
            guard slope > 1e-6 else { break }
            s = min(1, max(0, s - (curve(s, 0.42, 0.58) - t) / slope))
        }
        return curve(s, 0, 1)
    }
}

/// The glass surface inset within the window, with a soft shadow drawn behind it.
/// The shadow is masked to outside the glass so it doesn't tint the glass itself,
/// and its path is rebuilt in `layout()`, so it follows the glass on every frame
/// of a resize. Clicks in the transparent margin count as outside the panel.
private final class GlassContainerView: NSView {
    let glass = NSGlassEffectView()
    var onClickOutsideGlass: (() -> Void)?
    private let insets: NSEdgeInsets
    private let shadowView = NSView()
    // A sublayer rather than the view's own layer: AppKit resets shadow properties
    // on a view's backing layer to match `NSView.shadow`.
    private let shadowLayer = CALayer()
    private let shadowMask = CAShapeLayer()
    // Concentric with the 30 pt capsules inset 16 pt from the edge.
    private static let cornerRadius: CGFloat = 24

    init(insets: NSEdgeInsets) {
        self.insets = insets
        super.init(frame: .zero)
        shadowView.wantsLayer = true
        shadowLayer.shadowColor = NSColor.black.cgColor
        shadowLayer.shadowOpacity = 0.28
        shadowLayer.shadowRadius = 14
        shadowLayer.shadowOffset = CGSize(width: 0, height: -8)
        shadowMask.fillRule = .evenOdd
        shadowLayer.mask = shadowMask
        shadowView.layer?.addSublayer(shadowLayer)
        glass.style = .regular
        glass.cornerRadius = Self.cornerRadius
        addSubview(shadowView)
        addSubview(glass)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        let rect = NSRect(x: insets.left, y: insets.bottom,
                          width: max(0, bounds.width - insets.left - insets.right),
                          height: max(0, bounds.height - insets.top - insets.bottom))
        glass.frame = rect
        shadowView.frame = bounds
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        shadowLayer.frame = bounds
        shadowMask.frame = bounds
        let path = CGPath(roundedRect: rect, cornerWidth: Self.cornerRadius, cornerHeight: Self.cornerRadius, transform: nil)
        shadowLayer.shadowPath = path
        let mask = CGMutablePath()
        mask.addRect(bounds)
        mask.addPath(path)
        shadowMask.path = mask
        CATransaction.commit()
    }

    override func mouseDown(with event: NSEvent) { onClickOutsideGlass?() }
    override func rightMouseDown(with event: NSEvent) { onClickOutsideGlass?() }
}

private final class MixerPanel: NSPanel {
    var onEscape: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func cancelOperation(_ sender: Any?) { onEscape?() }
}
