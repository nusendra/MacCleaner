import AppKit
import SpaceLens
import SwiftUI

/// Renders the Toolbox page to a PNG without opening a window, for checking layout changes.
@MainActor
enum Snapshot {
    static func render(to url: URL, width: Double, scheme: ColorScheme) {
        let view = ToolboxGrid(viewModel: ToolboxViewModel()) { $0.destination.map { _ in {} } }
            .frame(width: width)
            .background(Color(nsColor: .windowBackgroundColor))
            .environment(\.colorScheme, scheme)
        write(view, to: url)
    }

    /// Scans `folder` and renders the Space Lens results screen.
    static func renderSpaceLens(folder: URL, to url: URL, size: CGSize, scheme: ColorScheme) {
        let semaphore = DispatchSemaphore(value: 0)
        let box = TreeBox()
        Task.detached {
            box.tree = try? await SpaceLensScanner().scan(folder)
            semaphore.signal()
        }
        semaphore.wait()
        guard let tree = box.tree else { return }
        let model = SpaceLensViewModel()
        model.show(tree)
        let view = SpaceLensResults(viewModel: model)
            .frame(width: size.width, height: size.height)
            .background(Color(nsColor: .windowBackgroundColor))
            .environment(\.colorScheme, scheme)
        write(view, to: url)
    }

    private final class TreeBox: @unchecked Sendable { var tree: SpaceLensNode? }

    private static func write(_ view: some View, to url: URL) {
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
