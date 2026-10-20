import Accelerate
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// One analysed photo.
public struct SimilarImage: Identifiable, Sendable {
    public var file: ScannedFile
    public var width: Int
    public var height: Int
    var hash: [UInt64]
    var noise: Double?
    var blur: Double?
    var dynamicRange: Double?
    /// One of the best shots of its group (CleanMyMac's "One of the best to keep").
    public var isBest = false
    /// Byte-identical to another photo (also reported under Duplicates).
    public var isExactCopy = false
    public var id: String { file.path }
}

public struct SimilarImageGroup: Identifiable, Sendable {
    public var images: [SimilarImage]
    public var id: String { images.first?.id ?? "" }
    public var size: Int64 { images.reduce(0) { $0 + $1.file.size } }
}

public enum SimilarImages {
    /// Summed Hamming distance over the four rotation hashes at or below which two photos are "similar".
    public static let threshold = 15

    public static func isImage(_ file: ScannedFile) -> Bool {
        let ext = file.url.pathExtension.lowercased()
        guard !file.isBundle, !ScanRules.ignoredImageExtensions.contains(ext), let type = UTType(filenameExtension: ext) else { return false }
        return type.conforms(to: .image)
    }

    public static func groups(in files: [ScannedFile], isCancelled: @escaping @Sendable () -> Bool = { false },
                              progress: @escaping @Sendable (Int, Int) -> Void = { _, _ in }) -> [SimilarImageGroup] {
        let images = files.filter(isImage)
        let analysed = ConcurrentMap.map(images, isCancelled: isCancelled, progress: progress) { analyse($0) }.compactMap { $0 }

        // Byte-identical photos are flagged (Duplicates lists them as such).
        var bySignature: [String: Int] = [:]
        var flagged = analysed
        for index in flagged.indices {
            guard let hash = DuplicateFinder.sampledHash(flagged[index].file) else { continue }
            let key = "\(flagged[index].file.size)-\(hash)"
            if let first = bySignature[key] {
                flagged[index].isExactCopy = true
                flagged[first].isExactCopy = true
            } else {
                bySignature[key] = index
            }
        }

        // Greedy first-fit, single linkage, in scan order.
        var clusters: [[SimilarImage]] = []
        for image in flagged {
            if let index = clusters.firstIndex(where: { $0.contains { distance($0.hash, image.hash) <= threshold } }) {
                clusters[index].append(image)
            } else {
                clusters.append([image])
            }
        }
        return clusters.filter { $0.count > 1 }.map { markBest(in: $0) }.map(SimilarImageGroup.init).sorted { $0.size > $1.size }
    }

    static func distance(_ a: [UInt64], _ b: [UInt64]) -> Int {
        zip(a, b).reduce(0) { $0 + ($1.0 ^ $1.1).nonzeroBitCount }
    }

    /// CleanMyMac's ranking: min-max normalise noise, blur, dynamic range and size within the group, score, keep the top 1–3.
    static func markBest(in group: [SimilarImage]) -> [SimilarImage] {
        func normaliser(_ values: [Double]) -> (Double) -> Double {
            guard let lo = values.min(), let hi = values.max(), hi > lo else { return { $0 } }
            return { ($0 - lo) / (hi - lo) }
        }
        let nNoise = normaliser(group.compactMap(\.noise)), nBlur = normaliser(group.compactMap(\.blur))
        let nDR = normaliser(group.compactMap(\.dynamicRange))
        let nW = normaliser(group.map { Double($0.width) }), nH = normaliser(group.map { Double($0.height) })
        let scores = group.map { image -> Double in
            let noise = image.noise.map(nNoise) ?? 1
            let blur = image.blur.map(nBlur) ?? 0
            let dr = image.dynamicRange.map(nDR) ?? 0
            return ((noise - 1) * (noise - 1) + blur * blur).squareRoot() + 0.3 * dr + 0.1 * nW(Double(image.width)) + 0.1 * nH(Double(image.height))
        }
        let keep = group.count >= 7 ? 3 : group.count >= 4 ? 2 : 1
        let best = Set(scores.enumerated().sorted { $0.element > $1.element }.prefix(keep).map(\.offset))
        return group.enumerated().map { index, image in
            var image = image
            image.isBest = best.contains(index)
            return image
        }.sorted { $0.isBest && !$1.isBest }
    }

    // MARK: Per-image analysis

    static func analyse(_ file: ScannedFile) -> SimilarImage? {
        guard let source = CGImageSourceCreateWithURL(file.url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(source) > 0, CGImageSourceGetStatus(source) == .statusComplete,
              let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceThumbnailMaxPixelSize: 256,
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceCreateThumbnailWithTransform: true,
              ] as CFDictionary)
        else { return nil }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let width = properties?[kCGImagePropertyPixelWidth] as? Int ?? thumbnail.width
        let height = properties?[kCGImagePropertyPixelHeight] as? Int ?? thumbnail.height

        guard max(thumbnail.width, thumbnail.height) >= 128, min(thumbnail.width, thumbnail.height) >= 32,
              let luma = Luma(thumbnail), let hash = perceptualHash(luma)
        else { return nil }
        return SimilarImage(file: file, width: width, height: height, hash: hash,
                            noise: noiseLevel(luma), blur: sharpness(luma), dynamicRange: dynamicRange(luma))
    }

    /// 8-bit luma (BT.709) of an image.
    struct Luma {
        var width: Int
        var height: Int
        var pixels: [UInt8]

        init?(_ image: CGImage) {
            width = image.width
            height = image.height
            var rgba = [UInt8](repeating: 0, count: width * height * 4)
            guard let context = CGContext(data: &rgba, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                          space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
            else { return nil }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            pixels = (0..<(width * height)).map { i in
                let r = Double(rgba[i * 4]), g = Double(rgba[i * 4 + 1]), b = Double(rgba[i * 4 + 2])
                return UInt8(min(255, (0.2126 * r + 0.7152 * g + 0.0722 * b).rounded()))
            }
        }

        subscript(x: Int, y: Int) -> Double { Double(pixels[min(max(y, 0), height - 1) * width + min(max(x, 0), width - 1)]) }
    }

    /// Sobel edges → 32×32 → 2-D DCT-II, top-left 8×8 against its mean, for 0/90/180/270° rotations: 256 bits.
    static func perceptualHash(_ luma: Luma) -> [UInt64]? {
        // Gradient magnitude (Sobel, divisor 8, clamped to 0…255).
        var magnitude = [Float](repeating: 0, count: luma.width * luma.height)
        for y in 0..<luma.height {
            for x in 0..<luma.width {
                let tl = luma[x - 1, y - 1], tc = luma[x, y - 1], tr = luma[x + 1, y - 1]
                let ml = luma[x - 1, y], mr = luma[x + 1, y]
                let bl = luma[x - 1, y + 1], bc = luma[x, y + 1], br = luma[x + 1, y + 1]
                // Negative responses clamp to 0, as the 8-bit vImage convolution does.
                let gx: Double = max(0, (tr + 2 * mr + br - tl - 2 * ml - bl) / 8)
                let gy: Double = max(0, (bl + 2 * bc + br - tl - 2 * tc - tr) / 8)
                magnitude[y * luma.width + x] = Float(min(255, (gx * gx + gy * gy).squareRoot())) / 255
            }
        }
        var small = resample(magnitude, width: luma.width, height: luma.height, to: 32)
        let dct = dctMatrix
        var hashes: [UInt64] = []
        for rotation in 0..<4 {
            if rotation > 0 { small = rotate90(small, size: 32) }
            let coefficients = transform(small, dct)
            var block: [Float] = []
            for row in 0..<8 { for col in 0..<8 { block.append(coefficients[row * 32 + col]) } }
            let mean = block.reduce(0, +) / 64
            var bits: UInt64 = 0
            for (i, value) in block.enumerated() where value >= mean { bits |= 1 << UInt64(i) }
            hashes.append(bits)
        }
        return hashes
    }

    /// Box-filter downscale to `size`×`size`.
    static func resample(_ source: [Float], width: Int, height: Int, to size: Int) -> [Float] {
        var out = [Float](repeating: 0, count: size * size)
        for y in 0..<size {
            for x in 0..<size {
                let x0 = x * width / size, x1 = max(x0 + 1, (x + 1) * width / size)
                let y0 = y * height / size, y1 = max(y0 + 1, (y + 1) * height / size)
                var sum: Float = 0
                for sy in y0..<min(y1, height) { for sx in x0..<min(x1, width) { sum += source[sy * width + sx] } }
                out[y * size + x] = sum / Float((min(y1, height) - y0) * (min(x1, width) - x0))
            }
        }
        return out
    }

    static func rotate90(_ m: [Float], size: Int) -> [Float] {
        var out = m
        for y in 0..<size { for x in 0..<size { out[x * size + (size - 1 - y)] = m[y * size + x] } }
        return out
    }

    /// DCT-II basis: C[0][n] = √(1/32), C[k][n] = ¼·cos(π(2n+1)k/64).
    static let dctMatrix: [Float] = {
        var matrix = [Float](repeating: 0, count: 32 * 32)
        for k in 0..<32 {
            for n in 0..<32 {
                let angle = Double.pi * Double(2 * n + 1) * Double(k) / 64
                matrix[k * 32 + n] = k == 0 ? Float((1.0 / 32.0).squareRoot()) : Float(0.25 * cos(angle))
            }
        }
        return matrix
    }()

    /// D = C·X·Cᵀ.
    static func transform(_ x: [Float], _ c: [Float]) -> [Float] {
        var cx = [Float](repeating: 0, count: 1024), result = [Float](repeating: 0, count: 1024)
        vDSP_mmul(c, 1, x, 1, &cx, 1, 32, 32, 32)
        var ct = [Float](repeating: 0, count: 1024)
        vDSP_mtrans(c, 1, &ct, 1, 32, 32)
        vDSP_mmul(cx, 1, ct, 1, &result, 1, 32, 32, 32)
        return result
    }

    /// Noise: smallest eigenvalue of the covariance of 8×8 patches (PCA noise estimate).
    static func noiseLevel(_ luma: Luma) -> Double? {
        var patches: [[Double]] = []
        stride(from: 0, through: luma.height - 8, by: 8).forEach { y in
            stride(from: 0, through: luma.width - 8, by: 8).forEach { x in
                patches.append((0..<64).map { luma[x + $0 % 8, y + $0 / 8] })
            }
        }
        guard patches.count > 64 else { return nil }
        let mean = (0..<64).map { i in patches.reduce(0) { $0 + $1[i] } / Double(patches.count) }
        var covariance = [Double](repeating: 0, count: 64 * 64)
        for patch in patches {
            for i in 0..<64 { for j in i..<64 { covariance[i * 64 + j] += (patch[i] - mean[i]) * (patch[j] - mean[j]) } }
        }
        for i in 0..<64 { for j in i..<64 {
            covariance[i * 64 + j] /= Double(patches.count - 1)
            covariance[j * 64 + i] = covariance[i * 64 + j]
        } }
        var jobz = CChar(UInt8(ascii: "N")), uplo = CChar(UInt8(ascii: "U"))
        var n = __LAPACK_int(64), lda = __LAPACK_int(64), info = __LAPACK_int(0), lwork = __LAPACK_int(64 * 4)
        var eigenvalues = [Double](repeating: 0, count: 64), work = [Double](repeating: 0, count: Int(lwork))
        dsyev_(&jobz, &uplo, &n, &covariance, &lda, &eigenvalues, &work, &lwork, &info)
        return info == 0 ? eigenvalues.first : nil
    }

    /// Sharpness: variance of a full 2-D Haar wavelet transform (higher = sharper).
    static func sharpness(_ luma: Luma) -> Double? {
        var size = 1
        while size * 2 <= min(luma.width, luma.height) { size *= 2 }
        guard size >= 8 else { return nil }
        var data = (0..<(size * size)).map { i in luma[i % size, i / size] }
        var length = size
        while length > 1 {
            for row in 0..<length { haar(&data, start: row * size, stride: 1, length: length) }
            for col in 0..<length { haar(&data, start: col, stride: size, length: length) }
            length /= 2
        }
        let mean = data.reduce(0, +) / Double(data.count)
        return data.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(data.count)
    }

    private static func haar(_ data: inout [Double], start: Int, stride: Int, length: Int) {
        let half = length / 2
        var tmp = [Double](repeating: 0, count: length)
        for i in 0..<half {
            let a = data[start + 2 * i * stride], b = data[start + (2 * i + 1) * stride]
            tmp[i] = (a + b) * 0.5
            tmp[half + i] = (a - b) * 0.5
        }
        for i in 0..<length { data[start + i * stride] = tmp[i] }
    }

    /// 20·log10(max/min) of the luma; undefined when the darkest pixel is pure black.
    static func dynamicRange(_ luma: Luma) -> Double? {
        guard let lo = luma.pixels.min(), let hi = luma.pixels.max(), lo > 0 else { return nil }
        return 20 * log10(Double(hi) / Double(lo))
    }
}
