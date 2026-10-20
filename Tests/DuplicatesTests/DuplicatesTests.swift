import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import Duplicates

private final class Sandbox {
    let root: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appending(path: "maccleaner-dups-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    @discardableResult
    func write(_ path: String, _ data: Data) throws -> URL {
        let url = root.appending(path: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
        return url
    }

    func scan() -> [ScannedFile] {
        FileEnumerator.files(under: root, rules: ScanRules(home: root.appending(path: "home"), root: root, hasFullDiskAccess: true), isCancelled: { false }) { _ in }
    }
}

private func randomData(_ count: Int, seed: UInt8) -> Data {
    var generator = seed
    return Data((0..<count).map { _ in generator = generator &* 31 &+ 7; return generator })
}

@Suite struct DuplicateFinderTests {
    @Test func groupsIdenticalFilesAndSkipsSmallOnes() throws {
        let box = try Sandbox()
        let content = randomData(200_000, seed: 1)
        try box.write("a/report.pdf", content)
        try box.write("b/report copy.pdf", content)
        try box.write("c/other.pdf", randomData(200_000, seed: 2))
        try box.write("tiny1.txt", Data(repeating: 1, count: 10))
        try box.write("tiny2.txt", Data(repeating: 1, count: 10))

        let groups = DuplicateFinder.groups(in: box.scan())
        #expect(groups.count == 1)
        let group = try #require(groups.first)
        #expect(Set(group.files.map(\.name)) == ["report.pdf", "report copy.pdf"])
        #expect(group.files[group.keptIndex].name == "report.pdf")
        #expect(group.wastedSize == 200_000)
    }

    @Test func largeFilesWithMatchingSamplesButDifferentContentAreNotDuplicates() throws {
        let box = try Sandbox()
        let size = 9 << 20
        let a = randomData(size, seed: 3)
        var b = a
        // Change a byte outside the four 1 MiB samples (at 0, s/4, s/2, 3s/4).
        let untouched = (size / 4) + (1 << 20) + 100
        b[untouched] = a[untouched] &+ 1
        try box.write("one.bin", a)
        try box.write("two.bin", b)
        #expect(DuplicateFinder.sampledHash(box.scan()[0]) == DuplicateFinder.sampledHash(box.scan()[1]))
        #expect(DuplicateFinder.groups(in: box.scan()).isEmpty)
    }

    @Test func hardLinksAreNotDuplicates() throws {
        let box = try Sandbox()
        let original = try box.write("photo.jpg", randomData(150_000, seed: 4))
        try FileManager.default.linkItem(at: original, to: box.root.appending(path: "link.jpg"))
        #expect(DuplicateFinder.groups(in: box.scan()).isEmpty)
    }

    @Test func ignoredFoldersAndExtensionsAreSkipped() throws {
        let box = try Sandbox()
        let data = randomData(150_000, seed: 5)
        try box.write("node_modules/x/lib.bin", data)
        try box.write("project/app.js", data)
        try box.write(".hidden/file.bin", data)
        try box.write("keep/file.bin", data)
        #expect(box.scan().map(\.name) == ["file.bin"])
    }
}

@Suite struct PrioritizerTests {
    @Test func copyNumbers() {
        #expect(DuplicatePrioritizer.copyNumber("Report.pdf") == nil)
        #expect(DuplicatePrioritizer.copyNumber("Report copy.pdf") == 1)
        #expect(DuplicatePrioritizer.copyNumber("Report copy 3.pdf") == 3)
        #expect(DuplicatePrioritizer.copyNumber("Photo 2.jpg") == 2)
        #expect(DuplicatePrioritizer.copyNumber("IMG_1234.jpg") == nil)
        #expect(DuplicatePrioritizer.copyNumber("Copy of notes.txt") == 1)
    }

    @Test func downloadsCopyIsRemovedFirstThenCopyNumbers() {
        func file(_ path: String, modified: TimeInterval = 0) -> ScannedFile {
            ScannedFile(url: URL(fileURLWithPath: path), size: 1, modified: Date(timeIntervalSince1970: modified), created: nil, isBundle: false, fileID: .init(device: 0, inode: 0))
        }
        let downloads = URL(fileURLWithPath: "/Users/me/Downloads")
        let sorted = DuplicatePrioritizer.sortedForKeeping([
            file("/Users/me/Downloads/report.pdf", modified: 9),
            file("/Users/me/Documents/report copy.pdf", modified: 5),
            file("/Users/me/Documents/report.pdf", modified: 1),
        ], downloads: downloads)
        #expect(sorted.map(\.path) == ["/Users/me/Documents/report.pdf", "/Users/me/Documents/report copy.pdf", "/Users/me/Downloads/report.pdf"])
    }
}

@Suite struct SimilarImageTests {
    /// A synthetic photo: smooth gradients plus a few shapes, so edges and DCT structure are realistic.
    private func makeImage(width: Int, height: Int, variant: Int) -> CGImage {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.7, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let w = CGFloat(width), h = CGFloat(height)
        if variant == 0 {
            context.setFillColor(CGColor(red: 0.95, green: 0.8, blue: 0.2, alpha: 1))
            context.fillEllipse(in: CGRect(x: w * 0.1, y: h * 0.5, width: w * 0.3, height: h * 0.3))
            context.setFillColor(CGColor(red: 0.1, green: 0.5, blue: 0.2, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: w, height: h * 0.3))
        } else {
            context.setFillColor(CGColor(red: 0.9, green: 0.1, blue: 0.1, alpha: 1))
            for i in 0..<6 { context.fill(CGRect(x: CGFloat(i) * w / 6, y: CGFloat(i % 2) * h / 2, width: w / 12, height: h / 2)) }
        }
        return context.makeImage()!
    }

    private func save(_ image: CGImage, to url: URL, quality: Double) throws {
        let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        #expect(CGImageDestinationFinalize(destination))
    }

    @Test func resizedReencodedPhotoIsSimilarButADifferentPhotoIsNot() throws {
        let box = try Sandbox()
        try save(makeImage(width: 2400, height: 1600, variant: 0), to: box.root.appending(path: "beach.jpg"), quality: 1)
        try save(makeImage(width: 1800, height: 1200, variant: 0), to: box.root.appending(path: "beach-small.jpg"), quality: 0.9)
        try save(makeImage(width: 2400, height: 1600, variant: 1), to: box.root.appending(path: "stripes.jpg"), quality: 1)
        // Flat-colour synthetic JPEGs fall under the 100 KiB scan minimum, so they are analysed directly.
        let all = try FileManager.default.contentsOfDirectory(at: box.root, includingPropertiesForKeys: nil).map {
            ScannedFile(url: $0, size: 200_000, modified: nil, created: nil, isBundle: false, fileID: .init(device: 0, inode: UInt64($0.path.hashValue.magnitude)))
        }
        let analysed = all.compactMap(SimilarImages.analyse)
        #expect(analysed.count == 3)
        let beach = try #require(analysed.first { $0.file.name == "beach.jpg" })
        let small = try #require(analysed.first { $0.file.name == "beach-small.jpg" })
        let stripes = try #require(analysed.first { $0.file.name == "stripes.jpg" })
        #expect(SimilarImages.distance(beach.hash, small.hash) <= SimilarImages.threshold)
        #expect(SimilarImages.distance(beach.hash, stripes.hash) > SimilarImages.threshold)

        let groups = SimilarImages.groups(in: all)
        #expect(groups.count == 1)
        #expect(Set(groups[0].images.map(\.file.name)) == ["beach.jpg", "beach-small.jpg"])
        #expect(groups[0].images.filter(\.isBest).count == 1)
    }

    @Test func bestShotCountGrowsWithGroupSize() {
        func image(_ i: Int) -> SimilarImage {
            SimilarImage(file: ScannedFile(url: URL(fileURLWithPath: "/x/\(i).jpg"), size: 1, modified: nil, created: nil, isBundle: false, fileID: .init(device: 0, inode: UInt64(i))),
                         width: 1000 + i, height: 800, hash: [0, 0, 0, 0], noise: Double(i), blur: Double(i), dynamicRange: 10)
        }
        #expect(SimilarImages.markBest(in: (0..<3).map(image)).filter(\.isBest).count == 1)
        #expect(SimilarImages.markBest(in: (0..<5).map(image)).filter(\.isBest).count == 2)
        #expect(SimilarImages.markBest(in: (0..<8).map(image)).filter(\.isBest).count == 3)
    }
}
