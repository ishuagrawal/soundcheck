import CoreAudio
import Foundation

/// Unmuted tap for waveform metering. Never replaces or writes an app's output.
/// Exists only while the menu panel is visible. A tiny transient PCM trace is
/// overwritten continuously for visualization; it is never recorded or exported.
final class MeterTap {
    private var tapID: AudioObjectID = 0
    private var aggregateID: AudioObjectID = 0
    private var procID: AudioDeviceIOProcID?
    private var state: OpaquePointer?
    let processes: [AudioObjectID]

    init(processes: [AudioObjectID]) throws {
        self.processes = processes
        do {
            let description = CATapDescription(stereoMixdownOfProcesses: processes)
            description.isPrivate = true
            description.muteBehavior = .unmuted
            description.name = "Soundcheck waveform"
            try HAL.check(AudioHardwareCreateProcessTap(description, &tapID), "Read app audio activity")
            let uid = try HAL.string(tapID, kAudioTapPropertyUID)
            let format = try HAL.value(tapID, kAudioTapPropertyFormat, default: AudioStreamBasicDescription())
            guard HAL.validFloatFormat(format) else {
                throw AudioFailure(operation: "Unsupported waveform format", status: kAudioHardwareUnsupportedOperationError)
            }
            let config: [String: Any] = [
                kAudioAggregateDeviceNameKey: "Soundcheck waveform",
                kAudioAggregateDeviceUIDKey: "com.ishu.Soundcheck.meter.\(UUID().uuidString)",
                kAudioAggregateDeviceIsPrivateKey: true,
                kAudioAggregateDeviceTapAutoStartKey: true,
                kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: uid, kAudioSubTapDriftCompensationKey: true]]
            ]
            try HAL.check(AudioHardwareCreateAggregateDevice(config as CFDictionary, &aggregateID), "Prepare app waveform")
            state = SoundcheckRenderCreate(0, 0, format.mChannelsPerFrame,
                                     format.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0, format.mSampleRate, 1)
            guard let state else { throw AudioFailure(operation: "Prepare app waveform", status: -1) }
            SoundcheckRenderSetVisualizing(state, true)
            try HAL.check(AudioDeviceCreateIOProcID(aggregateID, SoundcheckMeterIOProc, UnsafeMutableRawPointer(state), &procID), "Prepare waveform reader")
            try HAL.check(AudioDeviceStart(aggregateID, procID), "Read app waveform")
        } catch { stop(); throw error }
    }
    var peak: Float { state.map(SoundcheckRenderInputPeak) ?? 0 }
    var reading: AudioReading { .init(peak: peak, state: state) }
    deinit { stop() }
    private func stop() {
        if let procID, aggregateID != 0 {
            AudioDeviceStop(aggregateID, procID)
            AudioDeviceDestroyIOProcID(aggregateID, procID)
        }
        procID = nil
        if aggregateID != 0 { AudioHardwareDestroyAggregateDevice(aggregateID); aggregateID = 0 }
        if tapID != 0 { AudioHardwareDestroyProcessTap(tapID); tapID = 0 }
        if let state { SoundcheckRenderDestroy(state); self.state = nil }
    }
}
