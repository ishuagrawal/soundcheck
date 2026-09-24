import AppKit
import CoreAudio

@MainActor
final class AudioDiscovery {
    private var previouslyPlaying = Set<AudioObjectID>()
    private var metadata: [String: AppInfo] = [:]

    struct AppInfo {
        let id: String
        let name: String
        let icon: NSImage
        var sources: [AudioSource] = []
    }

    func scan(sources: [AudioSource]) -> [String: AppInfo] {
        let running = NSWorkspace.shared.runningApplications.filter {
            $0.processIdentifier != ProcessInfo.processInfo.processIdentifier && $0.activationPolicy == .regular
        }
        var apps: [String: AppInfo] = [:]
        for app in running {
            guard let id = app.bundleIdentifier else { continue }
            apps[id] = appInfo(app, id: id)
        }
        previouslyPlaying.formIntersection(sources.map(\.objectID))
        for source in sources {
            let object = source.objectID, pid = source.pid, bundle = source.bundleID
            if source.isPlaying { previouslyPlaying.insert(object) }
            guard source.isPlaying || previouslyPlaying.contains(object) else { continue }
            let owner = ownerApplication(pid: pid, audioBundle: bundle, running: running)
            // Unattributed audio daemons are output infrastructure, not app controls.
            // Showing another mixer's daemon would misleadingly control the whole mix.
            guard owner != nil || !bundle.isEmpty else { continue }
            let id = owner?.bundleIdentifier ?? (bundle.isEmpty ? "process.\(pid)" : bundle)
            guard id != Bundle.main.bundleIdentifier else { continue }
            if apps[id] == nil {
                if let owner { apps[id] = appInfo(owner, id: id) }
                else {
                    let name = bundle.split(separator: ".").last.map(String.init) ?? "Audio app"
                    apps[id] = .init(id: id, name: name, icon: NSImage(systemSymbolName: "app.dashed", accessibilityDescription: nil)!)
                }
            }
            apps[id]?.sources.append(source)
        }
        return apps
    }

    private func appInfo(_ app: NSRunningApplication, id: String) -> AppInfo {
        if let info = metadata[id] { return info }
        let info = AppInfo(id: id, name: app.localizedName ?? id,
                          icon: app.icon ?? NSImage(systemSymbolName: "app.dashed", accessibilityDescription: nil)!)
        metadata[id] = info
        return info
    }

    private func ownerApplication(pid: pid_t, audioBundle: String, running: [NSRunningApplication]) -> NSRunningApplication? {
        // Resolve the outer application bundle for Electron/Chromium nested helpers.
        // An exact bundle match is preferred; unrelated apps are never guessed by display name.
        if let exact = running.first(where: { $0.bundleIdentifier == audioBundle }) { return exact }
        var path = [CChar](repeating: 0, count: 4096) // PROC_PIDPATHINFO_MAXSIZE (4 * MAXPATHLEN)
        let count = proc_pidpath(pid, &path, UInt32(path.count))
        if count > 0 {
            let executable = String(decoding: path.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            if let match = running.first(where: { app in
                guard let url = app.bundleURL else { return false }
                return executable.hasPrefix(url.path + "/")
            }) { return match }
        }
        // WebKit XPC services can be outside their containing app bundle.
        // Follow a bounded, observed parent chain when the OS provides one.
        var candidate = pid
        for _ in 0..<8 {
            if let match = running.first(where: { $0.processIdentifier == candidate }) { return match }
            var info = proc_bsdinfo()
            let size = Int32(MemoryLayout<proc_bsdinfo>.size)
            guard proc_pidinfo(candidate, PROC_PIDTBSDINFO, 0, &info, size) == size else { break }
            let parent = pid_t(info.pbi_ppid)
            guard parent > 1, parent != candidate else { break }
            candidate = parent
        }
        if let app = NSRunningApplication(processIdentifier: pid), app.bundleIdentifier != nil { return app }
        return nil
    }

    nonisolated static func outputs() -> [OutputDevice] {
        ((try? HAL.objects(HAL.system, kAudioHardwarePropertyDevices)) ?? []).compactMap { device in
            // Never interrogate the layout of a private aggregate while the audio
            // queue is configuring its streams. Some HAL drivers serialize those
            // requests against stream-usage changes.
            guard let uid = try? HAL.string(device, kAudioDevicePropertyDeviceUID), !uid.hasPrefix("com.ishu.Soundcheck."),
                  let channels = try? HAL.bufferChannels(device, scope: kAudioObjectPropertyScopeOutput),
                  channels.reduce(0, +) > 0,
                  let name = try? HAL.string(device, kAudioObjectPropertyName) else { return nil }
            let transport = (try? HAL.value(device, kAudioDevicePropertyTransportType, default: UInt32(0))) ?? 0
            return .init(id: device, uid: uid, name: name, transport: transport)
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}
