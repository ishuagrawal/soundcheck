import CoreAudio
import Foundation

/// Confined to AudioEngine's serial control queue. The callback runs entirely in C.
final class TapRoute {
    let key: String
    let appID: String
    let deviceID: AudioObjectID
    let streamIndex: Int
    let isMuteOnly: Bool
    private(set) var processIDs: [AudioObjectID]
    private(set) var bundleIDs: [String]
    private(set) var sampleRate: Double = 0
    private(set) var tapID: AudioObjectID = 0
    private var aggregateID: AudioObjectID = 0
    private var ioProc: AudioDeviceIOProcID?
    private var render: OpaquePointer?
    private var description: CATapDescription?

    /// `muteOnly` is for a muted app that isn't running: a tap-only reader keeps it
    /// muted when it launches without opening a silent hardware stream. Running apps,
    /// muted or at 0%, use a playback route with gain 0, so toggles never rebuild it.
    init(key: String, appID: String, device: AudioObjectID, stream: Int, processes: [AudioObjectID], bundleIDs: [String],
         gain: Float, muteOnly: Bool) throws {
        self.key = key; self.appID = appID; deviceID = device; streamIndex = stream; processIDs = processes
        self.bundleIDs = bundleIDs
        isMuteOnly = muteOnly
        do { try start(gain: gain) } catch { stop(); throw error }
    }
    deinit { stop() }

    private func start(gain: Float) throws {
        let uid = try HAL.string(deviceID, kAudioDevicePropertyDeviceUID)
        let outputFormats = try HAL.streamFormats(deviceID, scope: kAudioObjectPropertyScopeOutput)
        guard outputFormats.indices.contains(streamIndex), HAL.validFloatFormat(outputFormats[streamIndex]) else {
            throw AudioFailure(operation: "This output's audio format isn't supported", status: kAudioHardwareUnsupportedOperationError)
        }
        let tap = CATapDescription(processes: processIDs, deviceUID: uid, stream: UInt(streamIndex))
        tap.name = "Soundcheck · \(appID)"
        tap.isPrivate = true
        tap.muteBehavior = .mutedWhenTapped
        // Bundle matching keeps new windows/helpers muted without waiting for polling.
        // Only app-owned identifiers are included, never generic shared WebKit IDs.
        tap.bundleIDs = bundleIDs
        tap.isProcessRestoreEnabled = false
        try HAL.check(AudioHardwareCreateProcessTap(tap, &tapID), "Create app audio control")
        description = tap
        let tapUID = try HAL.string(tapID, kAudioTapPropertyUID)
        let format = try HAL.value(tapID, kAudioTapPropertyFormat, default: AudioStreamBasicDescription())
        let outputFormat = outputFormats[streamIndex]
        guard HAL.validFloatFormat(format), format.mChannelsPerFrame == outputFormat.mChannelsPerFrame,
              format.mSampleRate == outputFormat.mSampleRate,
              (format.mFormatFlags & kAudioFormatFlagIsNonInterleaved) == (outputFormat.mFormatFlags & kAudioFormatFlagIsNonInterleaved) else {
            throw AudioFailure(operation: "The output changed its audio format. Try again", status: kAudioHardwareUnsupportedOperationError)
        }
        sampleRate = format.mSampleRate
        var config: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Soundcheck · \(appID)",
            kAudioAggregateDeviceUIDKey: "com.ishu.Soundcheck.\(UUID().uuidString)",
            kAudioAggregateDeviceMainSubDeviceKey: uid,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: uid]],
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: tapUID,
                                             kAudioSubTapDriftCompensationKey: true,
                                             kAudioSubTapDriftCompensationQualityKey: 127]]
        ]
        if isMuteOnly {
            // A muted app needs only a live reader. Avoid opening a silent hardware
            // playback stream (and any unrelated hardware input streams).
            config.removeValue(forKey: kAudioAggregateDeviceMainSubDeviceKey)
            config.removeValue(forKey: kAudioAggregateDeviceSubDeviceListKey)
        }
        try HAL.check(AudioHardwareCreateAggregateDevice(config as CFDictionary, &aggregateID), "Connect app to output")

        if isMuteOnly {
            render = SoundcheckRenderCreate(0, 0, format.mChannelsPerFrame,
                                     format.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0, sampleRate, 0)
            guard let render else { throw AudioFailure(operation: "Allocate app mute", status: OSStatus(memFullErr)) }
            try HAL.check(AudioDeviceCreateIOProcID(aggregateID, SoundcheckMeterIOProc, UnsafeMutableRawPointer(render), &ioProc), "Prepare app mute")
            try HAL.check(AudioDeviceStart(aggregateID, ioProc), "Start app mute")
            return
        }

        // Tap inputs follow the hardware subdevice's inputs. Validate the HAL's actual
        // layout before muting any source; never assume buffer 0 is the tap.
        let inputs = try HAL.bufferChannels(aggregateID, scope: kAudioObjectPropertyScopeInput)
        let outputs = try HAL.bufferChannels(aggregateID, scope: kAudioObjectPropertyScopeOutput)
        let planar = format.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0
        let tapBuffers = planar ? Int(format.mChannelsPerFrame) : 1
        let outputOffset = outputFormats.prefix(streamIndex).reduce(0) { count, format in
            count + (format.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0 ? Int(format.mChannelsPerFrame) : 1)
        }
        let channelsPerBuffer = planar ? UInt32(1) : format.mChannelsPerFrame
        guard inputs.count >= tapBuffers, outputs.count >= outputOffset + tapBuffers,
              inputs.suffix(tapBuffers).allSatisfy({ $0 == channelsPerBuffer }),
              outputs[outputOffset..<(outputOffset + tapBuffers)].allSatisfy({ $0 == channelsPerBuffer }) else {
            throw AudioFailure(operation: "This output's channel layout isn't supported", status: kAudioHardwareUnsupportedOperationError)
        }
        render = SoundcheckRenderCreate(UInt32(inputs.count - tapBuffers), UInt32(outputOffset), format.mChannelsPerFrame, planar, sampleRate, gain)
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
        try HAL.check(AudioDeviceStart(aggregateID, ioProc), "Start app audio; check audio access in System Settings")
    }

    func update(processes: [AudioObjectID], bundleIDs: [String], gain: Float) throws {
        let rememberedBundles = Array(Set(self.bundleIDs + bundleIDs)).sorted()
        if (processes != processIDs || rememberedBundles != self.bundleIDs), let description {
            description.processes = processes
            description.bundleIDs = rememberedBundles
            var property = HAL.address(kAudioTapPropertyDescription)
            var pointer = Unmanaged.passUnretained(description).toOpaque()
            try HAL.check(AudioObjectSetPropertyData(tapID, &property, 0, nil, UInt32(MemoryLayout<UnsafeMutableRawPointer>.size), &pointer), "Update app audio processes")
            processIDs = processes
            self.bundleIDs = rememberedBundles
        }
        if let render { SoundcheckRenderSetGain(render, gain) }
    }
    var inputPeak: Float { render.map(SoundcheckRenderInputPeak) ?? 0 }
    var outputPeak: Float { render.map(SoundcheckRenderOutputPeak) ?? 0 }
    func setVisualizing(_ enabled: Bool) { if let render { SoundcheckRenderSetVisualizing(render, enabled) } }
    var reading: AudioReading { .init(peak: outputPeak, state: render) }
    var callbacks: UInt64 { render.map(SoundcheckRenderCallbacks) ?? 0 }
    var fault: UInt32 { render.map(SoundcheckRenderFault) ?? 0 }
    func stop() {
        if let ioProc, aggregateID != 0 {
            AudioDeviceStop(aggregateID, ioProc)
            AudioDeviceDestroyIOProcID(aggregateID, ioProc)
        }
        ioProc = nil
        if aggregateID != 0 { AudioHardwareDestroyAggregateDevice(aggregateID); aggregateID = 0 }
        if tapID != 0 { AudioHardwareDestroyProcessTap(tapID); tapID = 0 }
        if let render { SoundcheckRenderDestroy(render); self.render = nil }
    }
}
