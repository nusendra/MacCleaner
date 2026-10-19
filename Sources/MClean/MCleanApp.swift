import AppKit
import SwiftUI

@main
struct MCleanApp: App {
    init() {
        // Running from `swift run` has no bundle, so promote the process to a regular foreground app.
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    var body: some Scene {
        WindowGroup("MClean") {
            ToolboxView()
        }
    }
}
