import XCTest
import AppKit
@testable import Soundcheck

final class VolumeTests: XCTestCase {
    func testMutePreservesLevel() throws {
        var pref = VolumePreference(volume: 0.37, isMuted: false)
        pref.isMuted = true
        XCTAssertEqual(pref.gain, 0)
        let restored = try JSONDecoder().decode(VolumePreference.self, from: JSONEncoder().encode(pref))
        XCTAssertEqual(restored.volume, 0.37)
        var unmuted = restored
        unmuted.isMuted = false
        XCTAssertEqual(unmuted.gain, 0.37, accuracy: 0.0001)
    }

    func testFullVolumeBypassesProcessingAndGainIsBounded() {
        XCTAssertFalse(VolumePreference().needsProcessing)
        XCTAssertTrue(VolumePreference(volume: 1, isMuted: true).needsProcessing)
        XCTAssertEqual(VolumePreference(volume: -4).gain, 0)
        XCTAssertEqual(VolumePreference(volume: 12).gain, 1)
        XCTAssertEqual(VolumePreference(volume: .nan).gain, 1)
    }

    func testBundleMatchingIncludesAppHelpersWithoutCapturingUnrelatedApps() {
        let app = AppSnapshot(id: "com.example.Browser", sources: [
            .init(objectID: 1, pid: 100, bundleID: "com.example.browser.helper", devices: [9], isPlaying: true),
            .init(objectID: 2, pid: 101, bundleID: "com.apple.WebKit.GPU", devices: [9], isPlaying: true)
        ], preference: .init(volume: 0.6, isMuted: true))
        XCTAssertEqual(app.matchingBundleIDs, ["com.example.Browser", "com.example.browser.helper"])
        XCTAssertEqual(app.preference.gain, 0)
    }

    @MainActor func testIndependentAppLevelsAndPersistence() {
        let name = "SoundcheckTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let model = MixerModel(defaults: defaults, startImmediately: false)
        let icon = NSImage(size: .init(width: 32, height: 32))
        let first = AppAudio(id: "test.first", name: "First", icon: icon)
        let second = AppAudio(id: "test.second", name: "Second", icon: icon)
        model.apps = [first, second]
        model.setVolume(0.42, for: first)
        model.toggleMute(first)
        XCTAssertEqual(second.preference.volume, 1)
        XCTAssertFalse(second.preference.isMuted)
        let saved = try! JSONDecoder().decode([String: VolumePreference].self, from: defaults.data(forKey: "appVolumes")!)
        XCTAssertEqual(saved["test.first"]?.volume, 0.42)
        XCTAssertEqual(saved["test.first"]?.isMuted, true)
        model.toggleMute(first)
        XCTAssertEqual(first.preference.gain, 0.42, accuracy: 0.0001)
        model.resetAll()
        XCTAssertFalse(first.preference.needsProcessing)
        XCTAssertFalse(second.preference.needsProcessing)
        model.stop()
    }

    @MainActor func testZeroVolumeReadsAsMutedAndUnmutesToHalf() {
        let name = "SoundcheckTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let model = MixerModel(defaults: defaults, startImmediately: false)
        let app = AppAudio(id: "test.zero", name: "Zero", icon: NSImage(size: .init(width: 32, height: 32)))
        model.apps = [app]
        model.setVolume(0, for: app)
        XCTAssertTrue(app.preference.isSilent)
        XCTAssertFalse(app.preference.isMuted)
        model.toggleMute(app)
        XCTAssertEqual(app.preference.volume, 0.5)
        XCTAssertFalse(app.preference.isSilent)
        model.stop()
    }

    func testFillStartsAtOneCircleAndGrowsWithEveryStep() {
        XCTAssertEqual(VolumeSlider.fillWidth(0, in: 270, height: 30), 30)
        XCTAssertEqual(VolumeSlider.fillWidth(0.01, in: 270, height: 30), 32.4, accuracy: 0.001)
        XCTAssertLessThan(VolumeSlider.fillWidth(0.04, in: 270, height: 30), VolumeSlider.fillWidth(0.05, in: 270, height: 30))
        XCTAssertEqual(VolumeSlider.fillWidth(0.5, in: 270, height: 30), 150)
        XCTAssertEqual(VolumeSlider.fillWidth(1, in: 270, height: 30), 270)
        XCTAssertEqual(VolumeSlider.fillWidth(.nan, in: 270, height: 30), 30)
    }
}
