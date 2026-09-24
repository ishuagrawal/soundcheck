import AppKit
import SwiftUI
import XCTest
@testable import Soundcheck

/// Renders the mixer offscreen for visual review. Skipped unless
/// SOUNDCHECK_SNAPSHOT_DIR is set (pass TEST_RUNNER_SOUNDCHECK_SNAPSHOT_DIR to xcodebuild).
/// Also writes `mixer-dark-clear@2x.png`, the panel content on a transparent
/// background, which `scripts/make-readme-image.swift` composites onto glass.
final class PanelSnapshotTests: XCTestCase {
    @MainActor func testRenderPanel() throws {
        guard let directory = ProcessInfo.processInfo.environment["SOUNDCHECK_SNAPSHOT_DIR"] else {
            throw XCTSkip("Set SOUNDCHECK_SNAPSHOT_DIR to render panel snapshots")
        }
        let suite = "SoundcheckSnapshot.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        for (name, dark) in [("dark", true), ("light", false)] {
            for state in ["mixer", "setup", "empty"] {
                let model = MixerModel(defaults: defaults, startImmediately: false)
                model.enabled = state != "setup"
                model.outputs = [.init(id: 1, uid: "a", name: "MacBook Pro Speakers", transport: kAudioDeviceTransportTypeBuiltIn),
                                 .init(id: 2, uid: "b", name: "AirPods Pro", transport: kAudioDeviceTransportTypeBluetooth)]
                model.outputID = 1
                model.outputVolume = 0.62
                model.outputCanChangeVolume = true
                model.outputCanMute = true
                model.isPanelVisible = true
                if state == "mixer" { model.apps = sampleApps() }
                try render(model, dark: dark, to: URL(fileURLWithPath: directory).appendingPathComponent("\(state)-\(name).png"))
                if state == "mixer" && dark {
                    try render(model, dark: dark, clear: true, scale: 2,
                               to: URL(fileURLWithPath: directory).appendingPathComponent("mixer-dark-clear@2x.png"))
                }
            }
        }
    }

    @MainActor private func sampleApps() -> [AppAudio] {
        let entries: [(String, String, String, Double, Bool, Float)] = [
            ("com.apple.Music", "Music", "/System/Applications/Music.app", 0.78, false, 0.5),
            ("com.apple.Safari", "Safari", "/Applications/Safari.app", 0.45, false, 0.3),
            ("us.zoom.xos", "Zoom", "/Applications/zoom.us.app", 1, false, 0.2),
            ("com.tinyspeck.slackmacgap", "Messages", "/System/Applications/Messages.app", 0.3, true, 0)
        ]
        return entries.enumerated().map { index, entry in
            let app = AppAudio(id: entry.0, name: entry.1, icon: NSWorkspace.shared.icon(forFile: URL(fileURLWithPath: entry.2).resolvingSymlinksInPath().path),
                               preference: .init(volume: entry.3, isMuted: entry.4))
            app.sources = [.init(objectID: AudioObjectID(index + 10), pid: 0, bundleID: entry.0, devices: [1], isPlaying: true)]
            if entry.5 > 0 {
                for step in 0..<AudioActivity.capacity {
                    let pcm = (0..<64).map { i in
                        Float(sin(Double(i) * 0.35 + Double(step)) * 0.7 + sin(Double(i) * 1.3) * 0.3)
                    }
                    let swell = Float(0.35 + 0.65 * abs(sin(Double(step) * 0.55 + Double(index))))
                    app.activity.append(peak: entry.5 * swell, trace: pcm, at: Date.timeIntervalSinceReferenceDate)
                }
            }
            return app
        }
    }

    @MainActor private func render(_ model: MixerModel, dark: Bool, clear: Bool = false, scale: CGFloat = 1, to url: URL) throws {
        let host = NSHostingView(rootView: MixerView(model: model))
        let size = host.fittingSize
        let container = NSView(frame: .init(origin: .zero, size: size))
        container.wantsLayer = true
        // Approximates the regular glass tint; real glass needs a live window server.
        container.layer?.backgroundColor = clear ? .clear
            : (dark ? NSColor(white: 0.16, alpha: 1) : NSColor(white: 0.95, alpha: 1)).cgColor
        container.layer?.cornerRadius = 24
        host.frame = container.bounds
        container.addSubview(host)
        let window = NSWindow(contentRect: container.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentView = container
        container.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { throw CocoaError(.fileWriteUnknown) }
        rep.size = size
        container.cacheDisplay(in: container.bounds, to: rep)
        try rep.representation(using: .png, properties: [:])?.write(to: url)
    }
}
