import AppKit
import CoreAudio
import Observation
import SwiftUI

struct VolumePreference: Codable, Equatable, Sendable {
    var volume: Double = 1
    var isMuted = false
    var gain: Float { isMuted ? 0 : Float(volume.isFinite ? min(1, max(0, volume)) : 1) }
    var needsProcessing: Bool { isMuted || volume < 0.9999 }
}

struct AudioSource: Equatable, Sendable {
    var objectID: AudioObjectID
    var pid: pid_t
    var bundleID: String
    var devices: [AudioObjectID]
    var isPlaying: Bool
}

struct AppSnapshot: Sendable {
    let id: String
    let sources: [AudioSource]
    let preference: VolumePreference
    var bundleHints: [String] = []
    var matchingBundleIDs: [String] {
        Array(Set([id] + (sources.map(\.bundleID) + bundleHints).filter {
            $0.lowercased() == id.lowercased() || $0.lowercased().hasPrefix(id.lowercased() + ".")
        })).sorted()
    }
}

@MainActor @Observable
final class AppAudio: Identifiable {
    let id: String
    var name: String
    var icon: NSImage
    let accent: Color
    var sources: [AudioSource] = []
    var bundleHints: [String] = []
    var preference: VolumePreference
    var error: String?
    var controlled = false
    var inputPeak: Float = 0
    var activity = AudioActivity()

    var isPlaying: Bool { sources.contains(where: \.isPlaying) }
    var snapshot: AppSnapshot { .init(id: id, sources: sources, preference: preference, bundleHints: bundleHints) }
    var status: String {
        if error != nil { return "Needs attention" }
        if preference.isMuted { return isPlaying ? "Muted" : "Muted when playing" }
        if isPlaying { return "Playing" }
        return preference.needsProcessing ? "Volume saved" : "Not playing"
    }

    init(id: String, name: String, icon: NSImage, preference: VolumePreference = .init()) {
        self.id = id; self.name = name; self.icon = icon; self.preference = preference
        accent = IconColor.extract(from: icon)
    }
}

@MainActor
enum IconColor {
    static func extract(from image: NSImage) -> Color {
        // Quantize saturated icon pixels into hue buckets. Ignore white backgrounds,
        // transparent corners and black glyphs so they don't drown out the app color.
        let size = 24
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
                                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: bitmap) else { return .secondary }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        image.draw(in: .init(x: 0, y: 0, width: size, height: size), from: .zero, operation: .copy, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        var weights = [CGFloat](repeating: 0, count: 24)
        var hues = [CGFloat](repeating: 0, count: 24)
        for y in 3..<(size - 3) {
            for x in 3..<(size - 3) {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                let saturation = color.saturationComponent, brightness = color.brightnessComponent
                guard color.alphaComponent > 0.7, saturation > 0.22, brightness > 0.2 else { continue }
                let hue = color.hueComponent
                let bucket = min(23, Int(hue * 24))
                let weight = saturation * brightness
                weights[bucket] += weight; hues[bucket] += hue * weight
            }
        }
        guard let dominant = weights.indices.max(by: { weights[$0] < weights[$1] }), weights[dominant] > 1 else {
            return Color(nsColor: .secondaryLabelColor)
        }
        return Color(hue: Double(hues[dominant] / weights[dominant]), saturation: 0.65, brightness: 0.76)
    }
}

struct OutputDevice: Identifiable, Equatable, Sendable {
    var id: AudioObjectID
    var uid: String
    var name: String
    var transport: UInt32
    var symbol: String {
        switch transport {
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE: "headphones"
        case kAudioDeviceTransportTypeBuiltIn: "laptopcomputer"
        case kAudioDeviceTransportTypeHDMI, kAudioDeviceTransportTypeDisplayPort: "display"
        case kAudioDeviceTransportTypeAirPlay: "airplay.audio"
        default: "hifispeaker"
        }
    }
}
