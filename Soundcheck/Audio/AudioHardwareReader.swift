import CoreAudio
import Foundation

struct HardwareSnapshot: Sendable {
    var sources: [AudioSource] = []
    var outputs: [OutputDevice] = []
    var outputID: AudioObjectID = 0
    var volume: Double = 1
    var muted = false
    var canMute = false
    var volumeElements: [AudioObjectPropertyElement] = []
}

/// HAL calls are synchronous IPC and can block in an external audio driver.
/// No hardware query or hardware volume write runs on the interface thread.
final class AudioHardwareReader: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.ishu.Soundcheck.audio-discovery", qos: .userInitiated)

    func read(completion: @escaping @MainActor @Sendable (Result<HardwareSnapshot, AudioFailure>) -> Void) {
        queue.async {
            let result: Result<HardwareSnapshot, AudioFailure>
            do {
                var snapshot = HardwareSnapshot()
                let objects = try HAL.objects(HAL.system, kAudioHardwarePropertyProcessObjectList)
                for object in objects {
                    guard let pid = try? HAL.value(object, kAudioProcessPropertyPID, default: pid_t(0)),
                          pid > 0, pid != getpid() else { continue }
                    let playing = (try? HAL.value(object, kAudioProcessPropertyIsRunningOutput, default: UInt32(0))) == 1
                    let bundle = (try? HAL.string(object, kAudioProcessPropertyBundleID)) ?? ""
                    let devices = (try? HAL.objects(object, kAudioProcessPropertyDevices, scope: kAudioObjectPropertyScopeOutput)) ?? []
                    snapshot.sources.append(.init(objectID: object, pid: pid, bundleID: bundle, devices: devices.sorted(), isPlaying: playing))
                }
                snapshot.outputs = AudioDiscovery.outputs()
                snapshot.outputID = try HAL.value(HAL.system, kAudioHardwarePropertyDefaultOutputDevice, default: AudioObjectID(0))
                let id = snapshot.outputID
                snapshot.volumeElements = HAL.isSettable(id, kAudioDevicePropertyVolumeScalar) ? [0] : [1, 2].filter {
                    HAL.isSettable(id, kAudioDevicePropertyVolumeScalar, element: $0)
                }
                snapshot.canMute = HAL.isSettable(id, kAudioDevicePropertyMute)
                let levels = snapshot.volumeElements.compactMap {
                    try? HAL.value(id, kAudioDevicePropertyVolumeScalar, scope: kAudioObjectPropertyScopeOutput, element: $0, default: Float32(1))
                }
                if !levels.isEmpty { snapshot.volume = Double(levels.reduce(0, +) / Float(levels.count)) }
                snapshot.muted = (try? HAL.value(id, kAudioDevicePropertyMute, scope: kAudioObjectPropertyScopeOutput, default: UInt32(0))) == 1
                result = .success(snapshot)
            } catch { result = .failure((error as? AudioFailure) ?? .init(operation: error.localizedDescription, status: -1)) }
            Task { @MainActor in completion(result) }
        }
    }

    func write(_ operation: @escaping @Sendable () throws -> Void,
               completion: @escaping @MainActor @Sendable (AudioFailure?) -> Void) {
        queue.async {
            var failure: AudioFailure?
            do { try operation() } catch { failure = (error as? AudioFailure) ?? .init(operation: error.localizedDescription, status: -1) }
            let result = failure
            Task { @MainActor in completion(result) }
        }
    }
}
