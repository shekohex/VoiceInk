import Cocoa
import SwiftUI

class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        updateActivationPolicy()
        cleanupLegacyUserDefaults()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        updateActivationPolicy()
        
        if !flag {
            createMainWindowIfNeeded()
        }
        return true
    }
    
    func applicationDidBecomeActive(_ notification: Notification) {
        updateActivationPolicy()
    }
    
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
    }
    
    private func updateActivationPolicy() {
        let isMenuBarOnly = UserDefaults.standard.bool(forKey: "IsMenuBarOnly")
        if isMenuBarOnly {
            NSApp.setActivationPolicy(.accessory)
        } else {
            NSApp.setActivationPolicy(.regular)
        }
    }
    
    private func createMainWindowIfNeeded() {
        if NSApp.windows.isEmpty {
            let contentView = ContentView()
            let hostingView = NSHostingView(rootView: contentView)
            let window = WindowManager.shared.createMainWindow(contentView: hostingView)
            window.makeKeyAndOrderFront(nil)
        } else {
            NSApp.windows.first?.makeKeyAndOrderFront(nil)
        }
    }

    private func cleanupLegacyUserDefaults() {
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: "defaultPowerModeConfigV2")
        defaults.removeObject(forKey: "isPowerModeEnabled")
    }
}
