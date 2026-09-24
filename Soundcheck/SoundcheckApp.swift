import AppKit
import SwiftUI

@main
struct SoundcheckApp {
    @MainActor static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) { app.run() }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = MixerModel(startImmediately: NSClassFromString("XCTestCase") == nil)
    private var statusItem: NSStatusItem?
    private var mixerPanel: MenuBarPanelController?
    private var statusIcon: StatusIconController?
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        guard NSClassFromString("XCTestCase") == nil else { return }
        let menuBar = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu(title: "Soundcheck")
        let quitItem = NSMenuItem(title: "Quit Soundcheck", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quitItem.target = NSApp
        appMenu.addItem(quitItem)
        appItem.submenu = appMenu
        menuBar.addItem(appItem)
        NSApp.mainMenu = menuBar
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem = item
        if let button = item.button {
            button.target = self
            button.action = #selector(togglePanel)
            statusIcon = StatusIconController(model: model, button: button)
        }
        mixerPanel = MenuBarPanelController(model: model, button: item.button)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in self?.mixerPanel?.show() }
    }
    @objc private func togglePanel() { mixerPanel?.toggle() }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        mixerPanel?.show(); return true
    }
    func applicationWillTerminate(_ notification: Notification) { model.stop() }
}
