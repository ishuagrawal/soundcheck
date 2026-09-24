import CoreAudio
import Foundation

/// Confined to AudioEngine's serial control queue. The callback runs entirely in C.
///
/// A route keeps one tap for its whole life. While audible, the tap is
/// `mutedWhenTapped` and an aggregate device reads it and plays it at the app's
/// gain; if reading ever stops, the app's own audio comes back. While muted, the
/// tap is `muted`, which silences the app with no reader, so the playback stream
/// is stopped and the hardware can idle. Mute and unmute only change the tap's
/// mode and start or stop the stream, in an order that never lets the app's
/// native audio through; adding a second tap to a playing app did.
final class TapRoute {
    let key: String
    let appID: String
    let deviceID: AudioObjectID
    let streamIndex: Int
    private(set) var isMuted: Bool
    private(set) var processIDs: [AudioObjectID]
    private(set) var bundleIDs: [String]
    private(set) var sampleRate: Double = 0
    private(set) var tapID: AudioObjectID = 0
    private var gain: Float
    private var deviceUID = ""
    private var outputFormats: [AudioStreamBasicDescription] = []
    private var tapFormat = AudioStreamBasicDescription()
    private var aggregateID: AudioObjectID = 0
    private var ioProc: AudioDeviceIOProcID?
    private var render: OpaquePointer?
    private var description: CATapDescription?
    private var playing = false

    /// Ramp length in the render kernel, plus a buffer or two of headroom.
    private static let fadeTime: useconds_t = 25_000

    init(key: String, appID: String, device: AudioObjectID, stream: Int, processes: [AudioObjectID], bundleIDs: [String],
         gain: Float, muted: Bool) throws {
        self.key = key; self.appID = appID; deviceID = device; streamIndex = stream; processIDs = processes
        self.bundleIDs = bundleIDs
        self.gain = gain
        isMuted = muted
        do {
            try createTap(muted: muted)
            // From the app's own full volume straight to its gain, as before any route existed.
            if !muted { try startPlayback(initialGain: gain) }
        } catch { stop(); throw error }
    }
    deinit { stop() }

    private func createTap(muted: Bool) throws {
        deviceUID = try HAL.string(deviceID, kAudioDevicePropertyDeviceUID)
        outputFormats = try HAL.streamFormats(deviceID, scope: kAudioObjectPropertyScopeOutput)
        guard outputFormats.indices.contains(streamIndex), HAL.validFloatFormat(outputFormats[streamIndex]) else {
            throw AudioFailure(operation: "This output's audio format isn't supported", status: kAudioHardwareUnsupportedOperationError)
        }
        let tap = CATapDescription(processes: processIDs, deviceUID: deviceUID, stream: UInt(streamIndex))
        tap.name = "Soundcheck · \(appID)"
        tap.isPrivate = true
        tap.muteBehavior = muted ? .muted : .mutedWhenTapped
        // Bundle matching keeps new windows/helpers muted without waiting for polling.
        // Only app-owned identifiers are included, never generic shared WebKit IDs.
        tap.bundleIDs = bundleIDs
        tap.isProcessRestoreEnabled = false
        try HAL.check(AudioHardwareCreateProcessTap(tap, &tapID), "Create app audio control")
        description = tap
        tapFormat = try HAL.value(tapID, kAudioTapPropertyFormat, default: AudioStreamBasicDescription())
        let outputFormat = outputFormats[streamIndex]
        guard HAL.validFloatFormat(tapFormat), tapFormat.mChannelsPerFrame == outputFormat.mChannelsPerFrame,
              tapFormat.mSampleRate == outputFormat.mSampleRate,
              (tapFormat.mFormatFlags & kAudioFormatFlagIsNonInterleaved) == (outputFormat.mFormatFlags & kAudioFormatFlagIsNonInterleaved) else {
            throw AudioFailure(operation: "The output changed its audio format. Try again", status: kAudioHardwareUnsupportedOperationError)
        }
        sampleRate = tapFormat.mSampleRate
    }

    /// Built on first use, so a route that starts muted never opens the hardware.
    private func buildPlayback(initialGain: Float) throws {
        let tapUID = try HAL.string(tapID, kAudioTapPropertyUID)
        let config: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Soundcheck · \(appID)",
            kAudioAggregateDeviceUIDKey: "com.ishu.Soundcheck.\(UUID().uuidString)",
            kAudioAggregateDeviceMainSubDeviceKey: deviceUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: deviceUID]],
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: tapUID,
                                             kAudioSubTapDriftCompensationKey: true,
                                             kAudioSubTapDriftCompensationQualityKey: 127]]
        ]
        try HAL.check(AudioHardwareCreateAggregateDevice(config as CFDictionary, &aggregateID), "Connect app to output")

        // Tap inputs follow the hardware subdevice's inputs. Validate the HAL's actual
        // layout before muting any source; never assume buffer 0 is the tap.
        let inputs = try HAL.bufferChannels(aggregateID, scope: kAudioObjectPropertyScopeInput)
        let outputs = try HAL.bufferChannels(aggregateID, scope: kAudioObjectPropertyScopeOutput)
        let planar = tapFormat.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0
        let tapBuffers = planar ? Int(tapFormat.mChannelsPerFrame) : 1
        let outputOffset = outputFormats.prefix(streamIndex).reduce(0) { count, format in
            count + (format.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0 ? Int(format.mChannelsPerFrame) : 1)
        }
        let channelsPerBuffer = planar ? UInt32(1) : tapFormat.mChannelsPerFrame
        guard inputs.count >= tapBuffers, outputs.count >= outputOffset + tapBuffers,
              inputs.suffix(tapBuffers).allSatisfy({ $0 == channelsPerBuffer }),
              outputs[outputOffset..<(outputOffset + tapBuffers)].allSatisfy({ $0 == channelsPerBuffer }) else {
            throw AudioFailure(operation: "This output's channel layout isn't supported", status: kAudioHardwareUnsupportedOperationError)
        }
        render = SoundcheckRenderCreate(UInt32(inputs.count - tapBuffers), UInt32(outputOffset), tapFormat.mChannelsPerFrame,
                                        planar, sampleRate, initialGain)
        guard let render else { throw AudioFailure(operation: "Allocate audio control", status: OSStatus(memFullErr)) }
        try HAL.check(AudioDeviceCreateIOProcID(aggregateID, SoundcheckAudioIOProc, UnsafeMutableRawPointer(render), &ioProc), "Prepare app audio")
        let inputStreams = try HAL.objects(aggregateID, kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeInput)
        guard let ioProc, !inputStreams.isEmpty else {
            throw AudioFailure(operation: "No app audio stream is available", status: kAudioHardwareBadStreamError)
        }
        if inputStreams.count > 1 {
            try HAL.check(SoundcheckSelectIOStream(aggregateID, ioProc, kAudioObjectPropertyScopeInput, UInt32(inputStreams.count - 1)), "Isolate app audio from hardware inputs")
        }
        if outputFormats.count > 1 {
            try HAL.check(SoundcheckSelectIOStream(aggregateID, ioProc, kAudioObjectPropertyScopeOutput, UInt32(streamIndex)), "Select app output stream")
        }
    }

    private func startPlayback(initialGain: Float) throws {
        if aggregateID == 0 {
            try buildPlayback(initialGain: initialGain)
        } else if let render {
            SoundcheckRenderSetGain(render, initialGain)
        }
        guard !playing, let ioProc else { return }
        try HAL.check(AudioDeviceStart(aggregateID, ioProc), "Start app audio; check audio access in System Settings")
        playing = true
    }

    private func stopPlayback() {
        guard playing, let ioProc else { return }
        AudioDeviceStop(aggregateID, ioProc)
        playing = false
    }

    private func applyDescription(_ operation: String) throws {
        guard let description else { return }
        var property = HAL.address(kAudioTapPropertyDescription)
        var pointer = Unmanaged.passUnretained(description).toOpaque()
        try HAL.check(AudioObjectSetPropertyData(tapID, &property, 0, nil, UInt32(MemoryLayout<UnsafeMutableRawPointer>.size), &pointer), operation)
    }

    private func setMuteBehavior(_ behavior: CATapMuteBehavior) throws {
        guard let description, description.muteBehavior != behavior else { return }
        description.muteBehavior = behavior
        try applyDescription("Change app mute")
    }

    /// Fade out, let the tap hold the mute on its own, then close the stream.
    private func mute() throws {
        if let render, playing {
            SoundcheckRenderSetGain(render, 0)
            usleep(Self.fadeTime)
        }
        try setMuteBehavior(.muted)
        stopPlayback()
        isMuted = true
    }

    /// Reopen the stream silently, hand the mute back to the reader only once it's
    /// reading, then fade up. The tap stays `muted` until then, so the app's own
    /// audio is never let through; if reading doesn't start in time, it stays
    /// `muted` and the route still plays the app.
    private func unmute() throws {
        try startPlayback(initialGain: 0)
        if let render {
            let start = SoundcheckRenderCallbacks(render)
            for _ in 0..<125 where SoundcheckRenderCallbacks(render) < start + 2 { usleep(2_000) }
            if SoundcheckRenderCallbacks(render) >= start + 2 { try setMuteBehavior(.mutedWhenTapped) }
            SoundcheckRenderSetGain(render, gain)
        }
        isMuted = false
    }

    func update(processes: [AudioObjectID], bundleIDs: [String], gain: Float, muted: Bool) throws {
        let rememberedBundles = Array(Set(self.bundleIDs + bundleIDs)).sorted()
        if (processes != processIDs || rememberedBundles != self.bundleIDs), let description {
            description.processes = processes
            description.bundleIDs = rememberedBundles
            try applyDescription("Update app audio processes")
            processIDs = processes
            self.bundleIDs = rememberedBundles
        }
        self.gain = gain
        if muted != isMuted {
            try muted ? mute() : unmute()
        } else if !muted, let render {
            SoundcheckRenderSetGain(render, gain)
        }
    }

    var inputPeak: Float { playing ? render.map(SoundcheckRenderInputPeak) ?? 0 : 0 }
    var outputPeak: Float { playing ? render.map(SoundcheckRenderOutputPeak) ?? 0 : 0 }
    func setVisualizing(_ enabled: Bool) { if let render { SoundcheckRenderSetVisualizing(render, enabled) } }
    var reading: AudioReading { playing ? .init(peak: outputPeak, state: render) : .init() }
    var callbacks: UInt64 { render.map(SoundcheckRenderCallbacks) ?? 0 }
    var fault: UInt32 { render.map(SoundcheckRenderFault) ?? 0 }
    func stop() {
        if let ioProc, aggregateID != 0 {
            if playing { AudioDeviceStop(aggregateID, ioProc) }
            AudioDeviceDestroyIOProcID(aggregateID, ioProc)
        }
        ioProc = nil
        playing = false
        if aggregateID != 0 { AudioHardwareDestroyAggregateDevice(aggregateID); aggregateID = 0 }
        if tapID != 0 { AudioHardwareDestroyProcessTap(tapID); tapID = 0 }
        if let render { SoundcheckRenderDestroy(render); self.render = nil }
    }
}
