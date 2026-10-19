import AppKit
import SwiftUI

/// Renders the Toolbox page to a PNG without opening a window, for checking layout changes.
@MainActor
enum Snapshot {
    static func render(to url: URL, width: Double, scheme: ColorScheme) {
        let view = ToolboxGrid(viewModel: ToolboxViewModel()) { $0.destination.map { _ in {} } }
            .frame(width: width)
            .background(Color(nsColor: .windowBackgroundColor))
            .environment(\.colorScheme, scheme)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        guard let image = renderer.nsImage, let tiff = image.tiffRepresentation,
              let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:])
        else {
            FileHandle.standardError.write(Data("snapshot failed\n".utf8))
            return
        }
        try? png.write(to: url)
    }
}
