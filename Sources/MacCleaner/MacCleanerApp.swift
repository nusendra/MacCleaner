import AppKit
import SwiftUI

@main
struct MacCleanerApp: App {
    init() {
        // Developer aid: `MacCleaner --snapshot out.png [width] [light|dark]` renders the Toolbox offscreen and exits.
        if let flag = CommandLine.arguments.firstIndex(of: "--snapshot"), CommandLine.arguments.count > flag + 1 {
            let args = CommandLine.arguments
            let width = args.count > flag + 2 ? Double(args[flag + 2]) ?? 900 : 900
            let scheme: ColorScheme = args.count > flag + 3 && args[flag + 3] == "dark" ? .dark : .light
            MainActor.assumeIsolated { Snapshot.render(to: URL(fileURLWithPath: args[flag + 1]), width: width, scheme: scheme) }
            exit(0)
        }
        // `MacCleaner --snapshot-lens out.png <folder> [light|dark]` scans the folder and renders Space Lens.
        if let flag = CommandLine.arguments.firstIndex(of: "--snapshot-lens"), CommandLine.arguments.count > flag + 2 {
            let args = CommandLine.arguments
            let scheme: ColorScheme = args.count > flag + 3 && args[flag + 3] == "dark" ? .dark : .light
            MainActor.assumeIsolated {
                Snapshot.renderSpaceLens(folder: URL(fileURLWithPath: args[flag + 2]), to: URL(fileURLWithPath: args[flag + 1]), size: CGSize(width: 1100, height: 720), scheme: scheme)
            }
            exit(0)
        }
        // Running from `swift run` has no bundle, so promote the process to a regular foreground app.
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    var body: some Scene {
        WindowGroup("MacCleaner") {
            ToolboxView()
        }
        // Fits the whole Toolbox (three columns, every card) without resizing.
        .defaultSize(width: 1000, height: 720)
    }
}
