import AppKit
import CoreAudio
import Observation
import ServiceManagement

@MainActor @Observable
final class MixerModel {
    var apps: [AppAudio] = []
    var outputs: [OutputDevice] = []
    var outputID: AudioObjectID = 0
    var outputVolume: Double = 1
    var outputMuted = false
    var outputCanChangeVolume = false
    var outputCanMute = false
    var enabled: Bool
    var isRequestingAccess = false
    var isBypassed = false
    var error: String?
    var launchAtLogin = SMAppService.mainApp.status == .enabled
    var routeCount = 0
    var showAllApps = false
    var isPanelVisible = false
    var audioConnectionStalled = false

    @ObservationIgnored private let discovery = AudioDiscovery()
    @ObservationIgnored private let hardware = AudioHardwareReader()
    @ObservationIgnored private var refreshing = false
    @ObservationIgnored private var stopped = false
    @ObservationIgnored private var discoveryWatchdog: Task<Void, Never>?
    @ObservationIgnored private let engine = AudioEngine()
    @ObservationIgnored private let defaults: UserDefaults
    private var preferences: [String: VolumePreference]
    @ObservationIgnored private var bundleHints: [String: [String]]
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var meterTimer: Timer?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var volumeElements: [AudioObjectPropertyElement] = []
    @ObservationIgnored private var sleeping = false
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var reconciling = false
    @ObservationIgnored private var reconcileAgain = false
    @ObservationIgnored private var meterReadInFlight = false
    @ObservationIgnored private var connectionWatchdog: Task<Void, Never>?

    var currentOutput: OutputDevice? { outputs.first { $0.id == outputID } }
    var visibleApps: [AppAudio] {
        apps.filter { showAllApps || $0.isPlaying || $0.preference.needsProcessing }
    }
    var playingCount: Int { apps.filter(\.isPlaying).count }
    var changedCount: Int { preferences.values.filter(\.needsProcessing).count }
    var status: String {
        if !enabled { return "One small setup" }
        if isBypassed { return "Controls paused" }
        if apps.contains(where: { $0.error != nil }) { return "Some apps need attention" }
        return playingCount == 0 ? "Ready when you are" : "\(playingCount) app\(playingCount == 1 ? "" : "s") playing"
    }

    init(defaults: UserDefaults = .standard, startImmediately: Bool = true) {
        self.defaults = defaults
        bundleHints = defaults.dictionary(forKey: "appAudioBundleIDs") as? [String: [String]] ?? [:]
        enabled = defaults.bool(forKey: "audioAccessEnabled")
        preferences = defaults.data(forKey: "appVolumes").flatMap {
            try? JSONDecoder().decode([String: VolumePreference].self, from: $0)
        } ?? [:]
        for key in preferences.keys {
            let level = preferences[key]!.volume
            preferences[key]?.volume = level.isFinite ? min(1, max(0, level)) : 1
        }
        if startImmediately { start() }
    }

    private func start() {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        timer?.tolerance = 0.2
        // App launches also trigger discovery; persistent bundle taps already cover
        // new helper processes without waiting for the one-second hardware poll.
        let center = NSWorkspace.shared.notificationCenter
        for notification in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            observers.append(center.addObserver(forName: notification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.refresh() }
            })
        }
        observers.append(center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.sleeping = true; self?.engine.shutdown() }
        })
        observers.append(center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.sleeping = false; self?.refresh() }
        })
    }

    func refresh() {
        guard !sleeping, !stopped, !refreshing else { return }
        refreshing = true
        // Populate recognizable app rows immediately, even if an audio driver stalls.
        if apps.isEmpty { applyApps(discovery.scan(sources: [])) }
        discoveryWatchdog?.cancel()
        discoveryWatchdog = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(5)) } catch { return }
            guard let self, self.refreshing, !self.stopped else { return }
            self.audioConnectionStalled = true
            self.error = "The audio connection is taking too long. Try reopening Soundcheck. Your saved mix is safe."
        }
        hardware.read { [weak self] result in
            guard let self else { return }
            refreshing = false
            discoveryWatchdog?.cancel()
            guard !sleeping, !stopped else { return }
            switch result {
            case .success(let snapshot):
                if audioConnectionStalled && !reconciling { error = nil; audioConnectionStalled = false }
                applyApps(discovery.scan(sources: snapshot.sources))
                outputs = snapshot.outputs
                outputID = snapshot.outputID
                volumeElements = snapshot.volumeElements
                outputCanChangeVolume = !volumeElements.isEmpty
                outputCanMute = snapshot.canMute
                outputVolume = snapshot.volume
                outputMuted = snapshot.muted
                reconcile()
            case .failure(let failure): error = "Couldn't read audio devices. \(failure.localizedDescription)"
            }
        }
    }

    private func applyApps(_ scanned: [String: AudioDiscovery.AppInfo]) {
            var existing = Dictionary(uniqueKeysWithValues: apps.map { ($0.id, $0) })
            for (id, info) in scanned {
                let app = existing[id] ?? AppAudio(id: id, name: info.name, icon: info.icon, preference: preferences[id] ?? .init())
                if app.name != info.name { app.name = info.name }
                if app.sources != info.sources { app.sources = info.sources }
                app.bundleHints = bundleHints[id] ?? []
                let learnedBundles = app.snapshot.matchingBundleIDs
                if learnedBundles != bundleHints[id] {
                    bundleHints[id] = learnedBundles
                    app.bundleHints = learnedBundles
                    defaults.set(bundleHints, forKey: "appAudioBundleIDs")
                }
                existing[id] = app
            }
            let updated = existing.values.filter { scanned[$0.id] != nil }.sorted {
                $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
            if apps.map(\.id) != updated.map(\.id) { apps = updated }
    }

    func setVolume(_ volume: Double, for app: AppAudio) {
        app.preference.volume = volume.isFinite ? min(1, max(0, volume)) : 1
        app.preference.isMuted = false
        save(app)
    }
    func toggleMute(_ app: AppAudio) { app.preference.isMuted.toggle(); save(app) }
    func reset(_ app: AppAudio) { app.preference = .init(); save(app) }
    func resetAll() {
        preferences.removeAll()
        for app in apps { app.preference = .init(); app.error = nil }
        persist(); reconcile()
    }
    private func save(_ app: AppAudio) {
        preferences[app.id] = app.preference
        app.error = nil
        persist(); reconcile()
    }
    private func persist() {
        if let data = try? JSONEncoder().encode(preferences) { defaults.set(data, forKey: "appVolumes") }
    }

    private func reconcile() {
        if reconciling { reconcileAgain = true; return }
        reconciling = true
        generation += 1
        let revision = generation
        connectionWatchdog?.cancel()
        connectionWatchdog = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(5)) } catch { return }
            guard let self, self.reconciling, self.generation == revision else { return }
            self.audioConnectionStalled = true
            self.error = "The audio connection is taking too long. Try reopening Soundcheck. Your saved mix is safe."
        }
        let runningIDs = Set(apps.map(\.id))
        let dormant = preferences.filter { !runningIDs.contains($0.key) && $0.value.isMuted }
            .map { AppSnapshot(id: $0.key, sources: [], preference: $0.value, bundleHints: bundleHints[$0.key] ?? []) }
        engine.reconcile(apps.map(\.snapshot) + dormant, enabled: enabled && !isBypassed && !sleeping,
                         metering: isPanelVisible) { [weak self] report in
            guard let self, revision == generation else { return }
            connectionWatchdog?.cancel()
            if audioConnectionStalled && !refreshing { error = nil; audioConnectionStalled = false }
            reconciling = false
            routeCount = report.routeCount
            for app in apps {
                app.controlled = report.controlled.contains(app.id)
                app.inputPeak = report.peaks[app.id] ?? 0
                if let message = report.errors[app.id] { app.error = message }
                else if app.controlled || !app.preference.needsProcessing { app.error = nil }
            }
            writeDiagnostics(report)
            if reconcileAgain { reconcileAgain = false; reconcile() }
        }
    }

    private func writeDiagnostics(_ report: EngineReport) {
        // Explicit development flag. Normal launches never write audio diagnostics.
        let arguments = ProcessInfo.processInfo.arguments
        guard let flag = arguments.firstIndex(of: "--diagnostics"), arguments.indices.contains(flag + 1) else { return }
        struct Diagnostic: Codable {
            struct App: Codable {
                let id: String; let name: String; let volume: Double; let muted: Bool
                let playing: Bool; let controlled: Bool; let error: String?
            }
            let timestamp: Date
            let enabled: Bool
            let panelVisible: Bool
            let output: String
            let apps: [App]
            let routes: [RouteDiagnostic]
        }
        let snapshot = Diagnostic(timestamp: Date(), enabled: enabled, panelVisible: isPanelVisible, output: currentOutput?.name ?? "None",
            apps: apps.map { .init(id: $0.id, name: $0.name, volume: $0.preference.volume, muted: $0.preference.isMuted,
                                  playing: $0.isPlaying, controlled: $0.controlled, error: $0.error) }, routes: report.routes)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(snapshot) { try? data.write(to: URL(fileURLWithPath: arguments[flag + 1]), options: .atomic) }
    }

    func setPanelVisible(_ visible: Bool) {
        isPanelVisible = visible
        meterTimer?.invalidate(); meterTimer = nil
        if visible {
            refresh()
            meterTimer = Timer.scheduledTimer(withTimeInterval: AudioActivity.interval, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.sampleLevels() }
            }
            meterTimer?.tolerance = 0.004
        } else {
            for app in apps { app.activity = AudioActivity() }
            reconcile()
        }
    }

    private func sampleLevels() {
        guard isPanelVisible, enabled, !isBypassed, !meterReadInFlight else { return }
        meterReadInFlight = true
        engine.readLevels { [weak self] levels in
            guard let self else { return }
            meterReadInFlight = false
            guard isPanelVisible else { return }
            for app in apps where app.isPlaying || app.activity.hasHistory {
                let reading = app.preference.isMuted ? AudioReading() : (levels[app.id] ?? AudioReading())
                app.activity.append(peak: reading.peak, trace: reading.trace)
            }
        }
    }

    func requestAccess() {
        guard !isRequestingAccess else { return }
        isRequestingAccess = true
        error = nil
        engine.requestAccess { [weak self] result in
            guard let self else { return }
            isRequestingAccess = false
            switch result {
            case .success:
                enabled = true
                defaults.set(true, forKey: "audioAccessEnabled")
                refresh()
            case .failure(let failure): error = failure.localizedDescription
            }
        }
    }
    func toggleBypass() { isBypassed.toggle(); reconcile() }
    func setOutput(_ id: AudioObjectID) {
        hardware.write({ try HAL.set(HAL.system, kAudioHardwarePropertyDefaultOutputDevice, value: id) }) { [weak self] failure in
            if let failure { self?.error = failure.localizedDescription } else { self?.refresh() }
        }
    }
    func setOutputVolume(_ volume: Double) {
        guard outputCanChangeVolume, !audioConnectionStalled else { return }
        let id = outputID, elements = volumeElements, unmute = outputMuted && outputCanMute
        outputVolume = min(1, max(0, volume)); outputMuted = false
        let value = Float32(outputVolume)
        hardware.write({
            for element in elements {
                try HAL.set(id, kAudioDevicePropertyVolumeScalar, scope: kAudioObjectPropertyScopeOutput, element: element, value: value)
            }
            if unmute { try HAL.set(id, kAudioDevicePropertyMute, scope: kAudioObjectPropertyScopeOutput, value: UInt32(0)) }
        }) { [weak self] failure in
            if let failure { self?.error = failure.localizedDescription }
        }
    }
    func toggleOutputMute() {
        guard outputCanMute, !audioConnectionStalled else { return }
        let id = outputID, value = UInt32(outputMuted ? 0 : 1)
        outputMuted.toggle()
        hardware.write({ try HAL.set(id, kAudioDevicePropertyMute, scope: kAudioObjectPropertyScopeOutput, value: value) }) { [weak self] failure in
            if let failure { self?.error = failure.localizedDescription }
        }
    }
    func setLaunchAtLogin(_ value: Bool) {
        do {
            if value { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            launchAtLogin = SMAppService.mainApp.status == .enabled
        } catch { self.error = "Couldn't change launch at login. \(error.localizedDescription)" }
    }
    func openAudioPrivacy() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_AudioCapture")!)
    }
    func openSoundSettings() { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Sound-Settings.extension")!) }
    func stop() {
        timer?.invalidate(); timer = nil
        meterTimer?.invalidate(); meterTimer = nil
        stopped = true
        connectionWatchdog?.cancel(); discoveryWatchdog?.cancel()
        for observer in observers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        observers.removeAll()
        engine.shutdown()
    }
}
