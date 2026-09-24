import CoreAudio
import Foundation

struct EngineReport: Sendable {
    var controlled: Set<String> = []
    var errors: [String: String] = [:]
    var peaks: [String: Float] = [:]
    var routeCount = 0
    var routes: [RouteDiagnostic] = []
}

struct RouteDiagnostic: Codable, Sendable {
    let appID: String
    let deviceID: UInt32
    let processes: [UInt32]
    let bundleIDs: [String]
    let callbacks: UInt64
    let inputPeak: Float
    let outputPeak: Float
    let fault: UInt32
}

final class AudioEngine: @unchecked Sendable {
    // All Core Audio graph mutation and route lifetimes are serialized here.
    private let queue = DispatchQueue(label: "com.ishu.Soundcheck.audio-control", qos: .userInitiated)
    private var routes: [String: TapRoute] = [:]
    private var meters: [String: MeterTap] = [:]
    private var failedUntil: [String: Date] = [:]

    func reconcile(_ apps: [AppSnapshot], enabled: Bool, metering: Bool,
                   completion: @escaping @MainActor @Sendable (EngineReport) -> Void) {
        queue.async { [self] in
            let report = configure(apps, enabled: enabled)
            configureMeters(apps, enabled: enabled && metering)
            Task { @MainActor in completion(report) }
        }
    }

    private func configure(_ apps: [AppSnapshot], enabled: Bool) -> EngineReport {
        guard enabled else { routes.removeAll(); meters.removeAll(); return .init() }
        let dormantMuted = Set(apps.filter { $0.preference.isMuted && $0.sources.isEmpty }.map(\.id))
        // Keep bundle-based mute taps alive through app/window restarts. Reset, unmute,
        // pause, and quit all release them explicitly.
        var wanted = Set(routes.values.filter { dormantMuted.contains($0.appID) }.map(\.key))
        var report = EngineReport()
        let fallback = (try? HAL.value(HAL.system, kAudioHardwarePropertyDefaultOutputDevice, default: AudioObjectID(0))) ?? 0
        for app in apps where app.preference.needsProcessing && (!app.sources.isEmpty || app.preference.isMuted) {
            var devices = Set(app.sources.flatMap { $0.devices.isEmpty ? [fallback] : $0.devices }).filter { $0 != 0 }
            if devices.isEmpty, app.preference.isMuted, fallback != 0 { devices = [fallback] }
            for device in devices {
                do {
                    let uid = try HAL.string(device, kAudioDevicePropertyDeviceUID)
                    guard !uid.hasPrefix("com.ishu.Soundcheck.") else {
                        throw AudioFailure(operation: "An app cannot route into Soundcheck's own private device", status: kAudioHardwareUnsupportedOperationError)
                    }
                    let formats = try HAL.streamFormats(device, scope: kAudioObjectPropertyScopeOutput)
                    let processes = app.sources.filter { $0.devices.contains(device) || ($0.devices.isEmpty && device == fallback) }.map(\.objectID).sorted()
                    for stream in formats.indices {
                        let key = "\(app.id)|\(uid)|\(stream)"
                        wanted.insert(key)
                        let muteOnly = app.preference.isMuted
                        // A route that no longer fits is replaced make-before-break: the old tap
                        // keeps the app's native audio muted until the new one is running.
                        // Destroying it first let the app play at full volume for the gap.
                        var replaced: TapRoute?
                        if let route = routes[key], route.sampleRate != formats[stream].mSampleRate || route.fault != 0 || route.isMuteOnly != muteOnly {
                            replaced = routes.removeValue(forKey: key)
                        }
                        if let route = routes[key] {
                            try route.update(processes: processes, bundleIDs: app.matchingBundleIDs, gain: app.preference.gain)
                        } else {
                            if let retry = failedUntil[key], retry > Date() {
                                // Keep the old route until a retry is due rather than unmute the app.
                                if let replaced { routes[key] = replaced }
                                continue
                            }
                            do {
                                try withExtendedLifetime(replaced) {
                                    routes[key] = try TapRoute(key: key, appID: app.id, device: device, stream: stream,
                                                              processes: processes, bundleIDs: app.matchingBundleIDs,
                                                              gain: app.preference.gain, muteOnly: muteOnly)
                                }
                                failedUntil.removeValue(forKey: key)
                            } catch {
                                failedUntil[key] = Date().addingTimeInterval(4)
                                throw error
                            }
                        }
                    }
                } catch {
                    report.errors[app.id] = error.localizedDescription
                    // Restoring the native route is safer than leaving an app silent.
                    for key in routes.keys.filter({ routes[$0]?.appID == app.id }) { routes.removeValue(forKey: key) }
                }
            }
        }
        for key in routes.keys where !wanted.contains(key) { routes.removeValue(forKey: key) }
        for route in routes.values {
            report.controlled.insert(route.appID)
            report.peaks[route.appID] = max(report.peaks[route.appID] ?? 0, route.inputPeak)
            report.routes.append(.init(appID: route.appID, deviceID: route.deviceID, processes: route.processIDs,
                                       bundleIDs: route.bundleIDs, callbacks: route.callbacks,
                                       inputPeak: route.inputPeak, outputPeak: route.outputPeak, fault: route.fault))
        }
        report.routeCount = routes.count
        return report
    }

    private func configureMeters(_ apps: [AppSnapshot], enabled: Bool) {
        for route in routes.values { route.setVisualizing(enabled && !route.isMuteOnly) }
        guard enabled else { meters.removeAll(); return }
        let controlled = Set(routes.values.map(\.appID))
        let wanted = apps.filter { !controlled.contains($0.id) && $0.sources.contains(where: \.isPlaying) }
        let ids = Set(wanted.map(\.id))
        for id in meters.keys where !ids.contains(id) { meters.removeValue(forKey: id) }
        for app in wanted {
            let processes = app.sources.map(\.objectID).sorted()
            if meters[app.id]?.processes != processes {
                meters.removeValue(forKey: app.id)
                meters[app.id] = try? MeterTap(processes: processes)
            }
        }
    }

    func readLevels(completion: @escaping @MainActor @Sendable ([String: AudioReading]) -> Void) {
        queue.async { [self] in
            var levels = meters.mapValues(\.reading)
            for route in routes.values {
                let reading = route.reading
                if reading.peak >= (levels[route.appID]?.peak ?? 0) { levels[route.appID] = reading }
            }
            let result = levels
            Task { @MainActor in completion(result) }
        }
    }

    func requestAccess(completion: @escaping @MainActor @Sendable (Result<Void, AudioFailure>) -> Void) {
        queue.async {
            // Public API only: a short unmuted tap triggers macOS's audio permission.
            // No output is rerouted and no samples are stored by this probe.
            var tapID: AudioObjectID = 0
            var deviceID: AudioObjectID = 0
            var procID: AudioDeviceIOProcID?
            var result: Result<Void, AudioFailure> = .success(())
            do {
                let description = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
                description.name = "Soundcheck audio access"
                description.isPrivate = true
                description.muteBehavior = .unmuted
                try HAL.check(AudioHardwareCreateProcessTap(description, &tapID), "Request app audio access")
                let uid = try HAL.string(tapID, kAudioTapPropertyUID)
                let config: [String: Any] = [
                    kAudioAggregateDeviceNameKey: "Soundcheck audio access",
                    kAudioAggregateDeviceUIDKey: "com.ishu.Soundcheck.permission.\(UUID().uuidString)",
                    kAudioAggregateDeviceIsPrivateKey: true,
                    kAudioAggregateDeviceTapAutoStartKey: true,
                    kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: uid]]
                ]
                try HAL.check(AudioHardwareCreateAggregateDevice(config as CFDictionary, &deviceID), "Prepare audio access")
                try HAL.check(AudioDeviceCreateIOProcIDWithBlock(&procID, deviceID, nil, { _, _, _, _, _ in }), "Prepare audio access")
                try HAL.check(AudioDeviceStart(deviceID, procID), "Audio access wasn't granted. Allow Soundcheck in System Settings")
            } catch {
                result = .failure((error as? AudioFailure) ?? .init(operation: error.localizedDescription, status: -1))
            }
            if let procID, deviceID != 0 {
                AudioDeviceStop(deviceID, procID)
                AudioDeviceDestroyIOProcID(deviceID, procID)
            }
            if deviceID != 0 { AudioHardwareDestroyAggregateDevice(deviceID) }
            if tapID != 0 { AudioHardwareDestroyProcessTap(tapID) }
            let finalResult = result
            Task { @MainActor in completion(finalResult) }
        }
    }

    func shutdown() {
        let cleanup = DispatchGroup()
        cleanup.enter()
        queue.async { [self] in
            routes.removeAll(); meters.removeAll()
            cleanup.leave()
        }
        // A stalled HAL driver must not prevent Quit or system sleep. Private
        // process taps are also released by Core Audio when the client exits.
        _ = cleanup.wait(timeout: .now() + .milliseconds(250))
    }
}
