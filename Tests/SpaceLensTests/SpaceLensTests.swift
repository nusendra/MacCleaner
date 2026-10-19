import Foundation
import Testing
@testable import SpaceLens

@Suite struct SpaceLensScannerTests {
    private func makeTree() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appending(path: "maccleaner-lens-\(UUID().uuidString)")
        let files: [(String, Int)] = [("big/a.bin", 400_000), ("big/b.bin", 100_000), ("small/c.txt", 10), ("top.bin", 200_000)]
        for (path, size) in files {
            let url = root.appending(path: path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(repeating: 7, count: size).write(to: url)
        }
        try FileManager.default.createSymbolicLink(atPath: root.appending(path: "link").path, withDestinationPath: "/usr")
        return root
    }

    @Test func buildsSortedTreeWithAggregatedAllocatedSizes() async throws {
        let root = try makeTree()
        defer { try? FileManager.default.removeItem(at: root) }
        let tree = try await SpaceLensScanner(hasFullDiskAccess: true).scan(root)

        #expect(tree.children.map(\.name).prefix(3) == ["big", "top.bin", "small"])
        let big = try #require(tree.children.first)
        #expect(big.size == big.children.reduce(0) { $0 + $1.size })
        #expect(big.size >= 500_000)
        #expect(tree.size == tree.children.reduce(0) { $0 + $1.size })
        // The symlink is a small file, not a walk into /usr.
        let link = try #require(tree.children.first { $0.name == "link" })
        #expect(link.kind == .file && link.size < 10_000)
    }

    @Test func privacyProtectedFoldersAreNotOpenedWithoutFullDiskAccess() async throws {
        let home = FileManager.default.temporaryDirectory.appending(path: "maccleaner-lens-home-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        try FileManager.default.createDirectory(at: home.appending(path: "Documents/deep"), withIntermediateDirectories: true)
        try Data(repeating: 1, count: 50_000).write(to: home.appending(path: "Documents/deep/file"))
        try FileManager.default.createDirectory(at: home.appending(path: "Music"), withIntermediateDirectories: true)

        let tree = try await SpaceLensScanner(hasFullDiskAccess: false, home: home).scan(home)
        let documents = try #require(tree.children.first { $0.name == "Documents" })
        #expect(documents.kind == .needsAccess && documents.children.isEmpty && !documents.isSelectable)
        #expect(tree.children.contains { $0.name == "Music" && $0.kind == .directory })
    }
}

@Suite struct SpaceLensPlannerTests {
    private func file(_ path: String, _ size: Int64, cloud: SpaceLensNode.CloudStatus = .notCloud) -> SpaceLensNode {
        SpaceLensNode(url: URL(fileURLWithPath: path), kind: .file, size: size, cloud: cloud)
    }

    @Test func wholeFolderGoesWhenEverythingInsideIsRemovable() {
        let folder = SpaceLensNode(url: URL(fileURLWithPath: "/x/f"), kind: .directory, children: [file("/x/f/a", 1), file("/x/f/b", 2)])
        let plan = SpaceLensDeletionPlanner.plan([folder, folder.children[0]])
        #expect(plan.map(\.path) == ["/x/f"])
    }

    @Test func plannerDescendsAroundCloudOnlyFiles() {
        let folder = SpaceLensNode(url: URL(fileURLWithPath: "/x/f"), kind: .directory, children: [file("/x/f/a", 5), file("/x/f/cloud", 0, cloud: .evicted)])
        #expect(SpaceLensDeletionPlanner.plan([folder]).map(\.path) == ["/x/f/a"])
    }

    @Test func removingANodeShrinksItsAncestors() {
        let inner = SpaceLensNode(url: URL(fileURLWithPath: "/x/f/g"), kind: .directory, children: [file("/x/f/g/a", 10)])
        let root = SpaceLensNode(url: URL(fileURLWithPath: "/x/f"), kind: .directory, children: [inner, file("/x/f/b", 3)])
        #expect(root.size == 13)
        inner.children[0].removeFromTree()
        #expect(inner.size == 0 && root.size == 3)
        #expect(root.children.first?.name == "b")
    }

    @Test func protectedPathsAreRecognised() {
        #expect(SpaceLensScanner.isProtectedPath("/System/Library", home: "/Users/me"))
        #expect(SpaceLensScanner.isProtectedPath("/Users/me/Documents", home: "/Users/me"))
        #expect(!SpaceLensScanner.isProtectedPath("/Users/me/Documents/old.zip", home: "/Users/me"))
    }
}

@Suite struct BubbleLayoutTests {
    @Test func splitKeepsSevenThenOnlyDominantItems() {
        let sizes: [Int64] = [1000, 900, 800, 700, 600, 500, 400, 300, 5, 4, 3, 2, 1]
        let (main, smaller) = BubbleLayout.split(sizes) { $0 }
        // 300 > 5+4+3+2+1 so it is shown; 5 is not bigger than 4+3+2+1=10, so the rest is "smaller".
        #expect(main == [1000, 900, 800, 700, 600, 500, 400, 300])
        #expect(smaller == [5, 4, 3, 2, 1])
    }

    @Test func splitCapsAtThirtyBubbles() {
        let sizes = (0..<60).map { Int64(1) << (60 - $0) } // each bigger than all smaller ones combined
        #expect(BubbleLayout.split(sizes) { $0 }.main.count == 30)
    }

    @Test func packedBubblesDoNotOverlapAndStayInsideTheView() throws {
        let sizes: [Int64] = [80_000_000_000, 30_000_000_000, 9_000_000_000, 4_000_000_000, 2_000_000_000, 900_000_000, 500_000_000, 100_000_000, 60_000_000]
        let rect = CGRect(x: 0, y: 0, width: 800, height: 600)
        let frames = BubbleLayout.frames(for: sizes, in: rect).compactMap { $0 }
        #expect(frames.count == sizes.count)
        let enclosing = CGRect(x: 100, y: 0, width: 600, height: 600).insetBy(dx: -1, dy: -1)
        for frame in frames {
            #expect(enclosing.contains(frame))
            #expect(frame.width >= BubbleLayout.minimumDiameter - 0.5)
        }
        for i in frames.indices {
            for j in frames.indices where j > i {
                let a = frames[i], b = frames[j]
                let distance = hypot(a.midX - b.midX, a.midY - b.midY)
                #expect(distance + 0.5 >= (a.width + b.width) / 2, "bubbles \(i) and \(j) overlap")
            }
        }
        // Largest first: the biggest size gets the biggest bubble.
        #expect(frames[0].width == frames.map(\.width).max())
    }

    @Test func singleBubbleFillsTheShortSideMinusPadding() throws {
        // The 12.5% packing padding is part of the enclosing circle, so a lone bubble is 300 / 1.125 wide.
        let frame = try #require(BubbleLayout.frames(for: [42], in: CGRect(x: 0, y: 0, width: 500, height: 300)).first ?? nil)
        #expect(abs(frame.width - 300 / 1.125) < 0.5 && abs(frame.midX - 250) < 0.5)
    }
}
