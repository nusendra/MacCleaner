import AppKit
import SwiftUI

@main
struct MCleanApp: App {
    init() {
        // Developer aid: `MClean --snapshot out.png [width] [light|dark]` renders the Toolbox offscreen and exits.
        if let flag = CommandLine.arguments.firstIndex(of: "--snapshot"), CommandLine.arguments.count > flag + 1 {
            let args = CommandLine.arguments
            let width = args.count > flag + 2 ? Double(args[flag + 2]) ?? 900 : 900
            let scheme: ColorScheme = args.count > flag + 3 && args[flag + 3] == "dark" ? .dark : .light
            MainActor.assumeIsolated { Snapshot.render(to: URL(fileURLWithPath: args[flag + 1]), width: width, scheme: scheme) }
            exit(0)
        }
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
