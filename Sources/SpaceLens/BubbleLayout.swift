import CoreGraphics
import Foundation

/// Space Lens bubble layout, following CleanMyMac's: a size-ranked split into bubbles and a "smaller items"
/// remainder, power-scaled radii, and d3-hierarchy's front-chain circle packing fitted into the view.
public enum BubbleLayout {
    /// Bubbles are never laid out smaller than this diameter (points) if the scaling can avoid it.
    public static let minimumDiameter: CGFloat = 48
    public static let power = 0.3
    /// Circles beyond this many are shrunk to almost nothing before packing.
    public static let maxPackedCircles = 38

    /// The 7 largest always get a bubble; after that the next one does while it is bigger than everything
    /// smaller combined, up to 30. The rest are returned as `smaller`.
    public static func split<T>(_ items: [T], size: (T) -> Int64) -> (main: [T], smaller: [T]) {
        let sorted = items.sorted { size($0) > size($1) }
        var main = Array(sorted.prefix(7))
        var rest = Array(sorted.dropFirst(main.count))
        var restSum = rest.reduce(Int64(0)) { $0 + size($1) }
        while let next = rest.first, main.count < 30 {
            let nextSize = size(next)
            if restSum - nextSize >= nextSize { break }
            main.append(next)
            rest.removeFirst()
            restSum -= nextSize
        }
        return (main, rest)
    }

    /// Frames for bubbles with the given sizes, in the same order, centred in `rect`. A frame is nil if the item
    /// could not be placed (non-finite) or, with `hideTooSmall`, would be under the minimum diameter.
    public static func frames(for sizes: [Int64], in rect: CGRect, hideTooSmall: Bool = false, iterations: Int = 10) -> [CGRect?] {
        guard rect.width > 0, rect.height > 0, !sizes.isEmpty else { return Array(repeating: nil, count: sizes.count) }
        let values = sizes.map { Double(max($0, 0)) }
        let minSide = Double(min(rect.width, rect.height))
        var low = 1e-13
        var high = max(values.max() ?? 1, 1)
        var best: [CGRect?] = Array(repeating: nil, count: sizes.count)
        var bestTooSmall = Int.max
        var bestMinimum = Double.greatestFiniteMagnitude

        for iteration in 0..<iterations {
            let offset = iteration == 0 ? 2e-13 : (high + low) / 2
            let circles = values.map { Circle(r: pow($0 + offset, power)) }
            pack(circles, into: 0.5)
            let scale = minSide // the enclosing circle has radius 0.5, i.e. diameter 1
            var tooSmall = 0
            var minimum = Double.greatestFiniteMagnitude
            var frames: [CGRect?] = []
            for circle in circles {
                let cx = Double(rect.midX) + scale * circle.x
                let cy = Double(rect.midY) + scale * circle.y
                let d = scale * 2 * circle.r
                guard cx.isFinite, cy.isFinite, d.isFinite else { frames.append(nil); continue }
                minimum = min(minimum, d)
                if d < Double(minimumDiameter) {
                    tooSmall += 1
                    if hideTooSmall { frames.append(nil); continue }
                }
                frames.append(CGRect(x: cx - d / 2, y: cy - d / 2, width: d, height: d))
            }
            if tooSmall < bestTooSmall || (tooSmall == bestTooSmall && minimum < bestMinimum) {
                best = frames
                bestTooSmall = tooSmall
                bestMinimum = minimum
            }
            // A larger offset flattens size differences; only grow it while bubbles are too small.
            if tooSmall > 0 { low = offset } else { high = offset }
        }
        return best
    }

    // MARK: Packing (d3-hierarchy pack, one level)

    final class Circle {
        var x = 0.0, y = 0.0, r: Double
        init(r: Double, x: Double = 0, y: Double = 0) {
            self.r = r
            self.x = x
            self.y = y
        }
    }

    /// Packs the circles around the origin and scales them so their enclosing circle has radius `target`.
    static func pack(_ circles: [Circle], into target: Double) {
        guard !circles.isEmpty else { return }
        let ordered = circles.sorted { $0.r > $1.r }
        for circle in ordered.dropFirst(maxPackedCircles) { circle.r /= 1000 }
        let padding = ordered.map { $0.r * 0.125 }
        for (circle, pad) in zip(ordered, padding) { circle.r += pad }
        let enclosing = packSiblings(ordered)
        for (circle, pad) in zip(ordered, padding) { circle.r -= pad }
        guard enclosing > 0 else { return }
        let k = target / enclosing
        for circle in circles {
            circle.x *= k
            circle.y *= k
            circle.r *= k
        }
    }

    private final class ChainNode {
        let circle: Circle
        unowned(unsafe) var next: ChainNode!
        unowned(unsafe) var previous: ChainNode!
        init(_ circle: Circle) { self.circle = circle }
    }

    /// d3's front-chain sibling packing. Returns the radius of the enclosing circle; circles end up centred on it.
    static func packSiblings(_ circles: [Circle]) -> Double {
        let n = circles.count
        guard n > 0 else { return 0 }
        let a0 = circles[0]
        a0.x = 0; a0.y = 0
        if n == 1 { return a0.r }
        let b0 = circles[1]
        a0.x = -b0.r; b0.x = a0.r; b0.y = 0
        if n == 2 { return a0.r + b0.r }
        place(b0, a0, circles[2])

        // Keep every chain node alive; the links themselves are unowned.
        var storage = [ChainNode(a0), ChainNode(b0), ChainNode(circles[2])]
        var a = storage[0], b = storage[1], c = storage[2]
        a.next = b; c.previous = b
        b.next = c; a.previous = c
        c.next = a; b.previous = a

        var i = 3
        outer: while i < n {
            place(a.circle, b.circle, circles[i])
            c = ChainNode(circles[i])
            storage.append(c)
            var j: ChainNode = b.next
            var k: ChainNode = a.previous
            var sj = b.circle.r
            var sk = a.circle.r
            repeat {
                if sj <= sk {
                    if intersects(j.circle, c.circle) {
                        b = j; a.next = b; b.previous = a
                        storage.removeLast()
                        continue outer // retry the same circle against the shortened chain
                    }
                    sj += j.circle.r
                    j = j.next
                } else {
                    if intersects(k.circle, c.circle) {
                        a = k; a.next = b; b.previous = a
                        storage.removeLast()
                        continue outer
                    }
                    sk += k.circle.r
                    k = k.previous
                }
            } while j !== k.next

            c.previous = a; c.next = b; a.next = c; b.previous = c; b = c
            var bestScore = score(a)
            var node: ChainNode = c.next
            while node !== b {
                let s = score(node)
                if s < bestScore { a = node; bestScore = s }
                node = node.next
            }
            b = a.next
            i += 1
        }

        var front = [b.circle]
        var node: ChainNode = b.next
        while node !== b {
            front.append(node.circle)
            node = node.next
        }
        let e = enclose(front)
        for circle in circles {
            circle.x -= e.x
            circle.y -= e.y
        }
        _ = storage // chain nodes must outlive the loop above
        return e.r
    }

    /// Places `c` tangent to both `a` and `b`.
    private static func place(_ b: Circle, _ a: Circle, _ c: Circle) {
        let dx = b.x - a.x, dy = b.y - a.y
        let d2 = dx * dx + dy * dy
        if d2 != 0 {
            var a2 = a.r + c.r; a2 *= a2
            var b2 = b.r + c.r; b2 *= b2
            if a2 > b2 {
                let x = (d2 + b2 - a2) / (2 * d2)
                let y = (max(0, b2 / d2 - x * x)).squareRoot()
                c.x = b.x - x * dx - y * dy
                c.y = b.y - x * dy + y * dx
            } else {
                let x = (d2 + a2 - b2) / (2 * d2)
                let y = (max(0, a2 / d2 - x * x)).squareRoot()
                c.x = a.x + x * dx - y * dy
                c.y = a.y + x * dy + y * dx
            }
        } else {
            c.x = a.x + c.r
            c.y = a.y
        }
    }

    private static func intersects(_ a: Circle, _ b: Circle) -> Bool {
        let dr = a.r + b.r - 1e-6, dx = b.x - a.x, dy = b.y - a.y
        return dr > 0 && dr * dr > dx * dx + dy * dy
    }

    private static func score(_ node: ChainNode) -> Double {
        let a = node.circle, b = node.next.circle
        let ab = a.r + b.r
        let dx = (a.x * b.r + b.x * a.r) / ab
        let dy = (a.y * b.r + b.y * a.r) / ab
        return dx * dx + dy * dy
    }

    // MARK: Smallest enclosing circle (d3 packEnclose / Welzl, deterministic order)

    struct Disc { var x: Double, y: Double, r: Double }

    static func enclose(_ circles: [Circle]) -> Disc {
        let points = circles.map { Disc(x: $0.x, y: $0.y, r: $0.r) }
        var basis: [Disc] = []
        var e: Disc?
        var i = 0
        while i < points.count {
            let p = points[i]
            if let current = e, enclosesWeak(current, p) {
                i += 1
            } else {
                basis = extendBasis(basis, p)
                e = encloseBasis(basis)
                i = 0
            }
        }
        return e ?? Disc(x: 0, y: 0, r: 0)
    }

    private static func extendBasis(_ basis: [Disc], _ p: Disc) -> [Disc] {
        if enclosesWeakAll(p, basis) { return [p] }
        for b in basis where enclosesNot(p, b) && enclosesWeakAll(encloseBasis2(b, p), basis) {
            return [b, p]
        }
        for i in 0..<max(0, basis.count - 1) {
            for j in (i + 1)..<basis.count {
                let bi = basis[i], bj = basis[j]
                if enclosesNot(encloseBasis2(bi, bj), p), enclosesNot(encloseBasis2(bi, p), bj),
                   enclosesNot(encloseBasis2(bj, p), bi), enclosesWeakAll(encloseBasis3(bi, bj, p), basis) {
                    return [bi, bj, p]
                }
            }
        }
        return [p] // numerically degenerate; restart the basis from this circle
    }

    private static func enclosesNot(_ a: Disc, _ b: Disc) -> Bool {
        let dr = a.r - b.r, dx = b.x - a.x, dy = b.y - a.y
        return dr < 0 || dr * dr < dx * dx + dy * dy
    }

    private static func enclosesWeak(_ a: Disc, _ b: Disc) -> Bool {
        let dr = a.r - b.r + max(a.r, b.r, 1) * 1e-9, dx = b.x - a.x, dy = b.y - a.y
        return dr > 0 && dr * dr > dx * dx + dy * dy
    }

    private static func enclosesWeakAll(_ a: Disc, _ basis: [Disc]) -> Bool {
        basis.allSatisfy { enclosesWeak(a, $0) }
    }

    private static func encloseBasis(_ basis: [Disc]) -> Disc {
        switch basis.count {
        case 1: basis[0]
        case 2: encloseBasis2(basis[0], basis[1])
        default: encloseBasis3(basis[0], basis[1], basis[2])
        }
    }

    private static func encloseBasis2(_ a: Disc, _ b: Disc) -> Disc {
        let x21 = b.x - a.x, y21 = b.y - a.y, r21 = b.r - a.r
        let l = (x21 * x21 + y21 * y21).squareRoot()
        guard l > 0 else { return a.r >= b.r ? a : b }
        return Disc(x: (a.x + b.x + x21 / l * r21) / 2, y: (a.y + b.y + y21 / l * r21) / 2, r: (l + a.r + b.r) / 2)
    }

    private static func encloseBasis3(_ a: Disc, _ b: Disc, _ c: Disc) -> Disc {
        let x1 = a.x, y1 = a.y, r1 = a.r
        let x2 = b.x, y2 = b.y, r2 = b.r
        let x3 = c.x, y3 = c.y, r3 = c.r
        let a2 = x1 - x2, a3 = x1 - x3, b2 = y1 - y2, b3 = y1 - y3, c2 = r2 - r1, c3 = r3 - r1
        let d1 = x1 * x1 + y1 * y1 - r1 * r1
        let d2 = d1 - x2 * x2 - y2 * y2 + r2 * r2
        let d3 = d1 - x3 * x3 - y3 * y3 + r3 * r3
        let ab = a3 * b2 - a2 * b3
        let xa = (b2 * d3 - b3 * d2) / (ab * 2) - x1, xb = (b3 * c2 - b2 * c3) / ab
        let ya = (a3 * d2 - a2 * d3) / (ab * 2) - y1, yb = (a2 * c3 - a3 * c2) / ab
        let qa = xb * xb + yb * yb - 1
        let qb = 2 * (r1 + xa * xb + ya * yb)
        let qc = xa * xa + ya * ya - r1 * r1
        let r = -(abs(qa) > 1e-6 ? (qb + (qb * qb - 4 * qa * qc).squareRoot()) / (2 * qa) : qc / qb)
        return Disc(x: x1 + xa + xb * r, y: y1 + ya + yb * r, r: r)
    }
}
