import AppKit
import AVFAudio

// Opt-in integration fixture: two instances with the same bundle ID simulate two
// windows/helper processes from the same app. Quiet audio; exits after 90 seconds.
final class Oscillator: @unchecked Sendable {
    var phase = 0.0
    let frequency: Double
    init(_ frequency: Double) { self.frequency = frequency }
}
@main struct ToneFixture {
    @MainActor static func main() throws {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let engine = AVAudioEngine()
        let format = engine.outputNode.inputFormat(forBus: 0)
        let oscillator = Oscillator(Double(CommandLine.arguments.dropFirst().first ?? "440") ?? 440)
        let node = AVAudioSourceNode(format: format) { _, _, frames, buffers in
            let audio = UnsafeMutableAudioBufferListPointer(buffers)
            for frame in 0..<Int(frames) {
                let sample = Float(sin(oscillator.phase) * 0.015)
                oscillator.phase += 2 * .pi * oscillator.frequency / format.sampleRate
                if oscillator.phase >= 2 * .pi { oscillator.phase -= 2 * .pi }
                for buffer in audio {
                    guard let data = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
                    for channel in 0..<Int(buffer.mNumberChannels) { data[frame * Int(buffer.mNumberChannels) + channel] = sample }
                }
            }
            return noErr
        }
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
        try engine.start()
        DispatchQueue.main.asyncAfter(deadline: .now() + 90) { app.terminate(nil) }
        app.run()
        engine.stop()
    }
}
