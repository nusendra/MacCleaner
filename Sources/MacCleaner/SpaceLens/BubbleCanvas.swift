import AppKit
import SpaceLens
import SwiftUI

/// Colours from CleanMyMac's Space Lens bubble config.
enum LensColors {
    static let stroke = Color(red: 0.62, green: 0.38, blue: 1.0)
    static let selected = Color(red: 1.0, green: 0.51, blue: 0.92)
    static let purgeable = Color(red: 0.38, green: 0.62, blue: 1.0)
}

/// Superellipse ("squircle") with exponent 2.16, the outline Space Lens draws instead of a circle.
struct Squircle: Shape {
    var exponent: Double = 2.16

    func path(in rect: CGRect) -> Path {
        let a = rect.width / 2, b = rect.height / 2
        let steps = 96
        var path = Path()
        for step in 0...steps {
            let t = Double(step) / Double(steps) * 2 * .pi
            let c = cos(t), s = sin(t)
            let x = a * CGFloat(copysign(pow(abs(c), 2 / exponent), c))
            let y = b * CGFloat(copysign(pow(abs(s), 2 / exponent), s))
            let point = CGPoint(x: rect.midX + x, y: rect.midY + y)
            step == 0 ? path.move(to: point) : path.addLine(to: point)
        }
        path.closeSubpath()
        return path
    }
}

/// One entry of the canvas: a real node, or the aggregate of the smaller items.
struct BubbleItem: Identifiable {
    enum Content {
        case node(SpaceLensNode)
        case smaller([SpaceLensNode], size: Int64)
    }

    var content: Content
    var id: String {
        switch content {
        case .node(let node): "\(ObjectIdentifier(node).hashValue)"
        case .smaller: "smaller-items"
        }
    }

    var size: Int64 {
        switch content {
        case .node(let node): node.size
        case .smaller(_, let size): size
        }
    }
}

struct BubbleCanvas: View {
    @ObservedObject var viewModel: SpaceLensViewModel

    var body: some View {
        GeometryReader { proxy in
            let level = viewModel.level
            let items = bubbleItems(level)
            let frames = BubbleLayout.frames(for: items.map(\.size), in: CGRect(origin: .zero, size: proxy.size).insetBy(dx: 12, dy: 12))
            ZStack {
                // Double-clicking empty space goes up a level.
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) { viewModel.goUp() }
                ForEach(Array(zip(items, frames)), id: \.0.id) { item, frame in
                    if let frame {
                        BubbleView(item: item, viewModel: viewModel)
                            .frame(width: frame.width, height: frame.height)
                            .position(x: frame.midX, y: frame.midY)
                            .transition(.scale(scale: 0.6).combined(with: .opacity))
                    }
                }
            }
            .id(viewModel.current.map { ObjectIdentifier($0) })
            .transition(.opacity)
            .animation(.timingCurve(0.4, 0.6, 0, 1, duration: 0.7), value: viewModel.current.map { ObjectIdentifier($0) })
        }
    }

    private func bubbleItems(_ level: LensLevel) -> [BubbleItem] {
        var items = level.main.map { BubbleItem(content: .node($0)) }
        if !level.smaller.isEmpty { items.append(BubbleItem(content: .smaller(level.smaller, size: level.smallerSize))) }
        items += level.other.filter { $0.kind == .purgeable }.map { BubbleItem(content: .node($0)) }
        return items
    }
}

struct BubbleView: View {
    let item: BubbleItem
    @ObservedObject var viewModel: SpaceLensViewModel
    @State private var hovered = false

    var body: some View {
        GeometryReader { proxy in
            let w = proxy.size.width
            let showsText = w >= 80
            let twoLines = w >= 115
            ZStack {
                Squircle()
                    .fill(fill)
                Squircle()
                    .stroke(strokeColor, lineWidth: strokeWidth(w))
                    .clipShape(Squircle()) // only the inner half shows, as in Space Lens
                VStack(spacing: w * 0.03) {
                    icon
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: w * (showsText ? 0.4 : 0.5), height: w * (showsText ? 0.4 : 0.5))
                        .accessibilityHidden(true)
                    if showsText {
                        Text(title)
                            .font(.system(size: fontSize(w), weight: .semibold))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        if twoLines {
                            Text(item.size.formattedBytes)
                                .font(.system(size: fontSize(w) * 0.85))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(.horizontal, w / 6)
                .offset(y: showsText ? w * 0.04 : 0)
                if showsCheckmark { checkmark(in: proxy.size) }
            }
            .contentShape(Squircle())
            .onHover { hovered = $0 }
            .onTapGesture { open() }
            .help(tooltip)
            .contextMenu { menu }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(title), \(item.size.formattedBytes)")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { open() }
        }
    }

    private var node: SpaceLensNode? {
        if case .node(let node) = item.content { return node }
        return nil
    }

    private var title: String {
        switch item.content {
        case .node(let node): node.displayName
        case .smaller: "Smaller items"
        }
    }

    private var state: CheckState {
        switch item.content {
        case .node(let node): viewModel.state(of: node)
        case .smaller(let items, _): viewModel.state(of: items)
        }
    }

    private var isSelectable: Bool {
        switch item.content {
        case .node(let node): node.isSelectable
        case .smaller(let items, _): items.contains(where: \.isSelectable)
        }
    }

    private var isPurgeable: Bool { node?.kind == .purgeable }

    private var fill: some ShapeStyle {
        let base = isPurgeable ? LensColors.purgeable : (state == .on ? LensColors.selected : LensColors.stroke)
        return RadialGradient(
            colors: [base.opacity(hovered ? 0.30 : 0.20), base.opacity(hovered ? 0.16 : 0.08)],
            center: .init(x: 0.35, y: 0.3), startRadius: 0, endRadius: 400
        )
    }

    private var strokeColor: Color {
        isPurgeable ? LensColors.purgeable : (state == .on ? LensColors.selected : LensColors.stroke)
    }

    /// `min(base * 2, width / 6)` with base 1, or 5 while hovered.
    private func strokeWidth(_ w: CGFloat) -> CGFloat { min((hovered ? 5 : 1) * 2, w / 6) }

    private func fontSize(_ w: CGFloat) -> CGFloat { min(max(w.squareRoot(), 11), 22) }

    private var icon: Image {
        switch item.content {
        case .smaller: return Image(systemName: "square.grid.3x3.fill")
        case .node(let node):
            if node.kind == .purgeable { return Image(systemName: "externaldrive.badge.timemachine") }
            return Image(nsImage: LensIcons.icon(for: node))
        }
    }

    private var showsCheckmark: Bool { isSelectable && (hovered || state != .off) }

    /// Sits on the rim at 40°, like Space Lens's checkmark accessory.
    private func checkmark(in size: CGSize) -> some View {
        let n = 2.16, angle = 40.0 * .pi / 180
        let radius = size.width / 2 - min(2, size.width / 6) - 6
        let t = tan(angle)
        let x = radius / pow(1 + pow(t, n), 1 / n)
        let y = x * t
        return Image(systemName: state == .on ? "checkmark.circle.fill" : state == .mixed ? "minus.circle.fill" : "circle")
            .font(.system(size: 20))
            .symbolRenderingMode(.palette)
            .foregroundStyle(.white, state == .off ? Color.secondary : LensColors.selected)
            .background(Circle().fill(Color(nsColor: .windowBackgroundColor)).padding(2))
            .frame(width: 30, height: 30)
            .contentShape(Circle())
            .onTapGesture { toggle() }
            .position(x: size.width / 2 + x, y: size.height / 2 - y)
            .accessibilityLabel(state == .on ? "Deselect \(title)" : "Select \(title)")
    }

    private var tooltip: String {
        var lines = ["\(title)", "Size: \(item.size.formattedBytes)"]
        if case .smaller(let items, _) = item.content { lines.append("\(items.count) items") }
        if case .node(let node) = item.content {
            if node.kind == .purgeable { lines.append("Space macOS frees automatically when needed") }
            if node.isProtected { lines.append("System item: cannot be removed") }
            if node.cloud == .evicted { lines.append("Cloud-only: takes no space on this Mac") }
        }
        return lines.joined(separator: "\n")
    }

    @ViewBuilder
    private var menu: some View {
        if isSelectable {
            Button(state == .on ? "Deselect “\(title)”" : "Select “\(title)”") { toggle() }
        }
        if let node, node.kind != .purgeable {
            if node.isDirectory { Button("Open") { viewModel.open(node) } }
            Button("Reveal in Finder") { viewModel.reveal(node) }
        }
    }

    private func toggle() {
        switch item.content {
        case .node(let node): viewModel.toggle(node)
        case .smaller(let items, _): viewModel.toggle(items)
        }
    }

    private func open() {
        switch item.content {
        case .node(let node): viewModel.open(node)
        case .smaller: viewModel.smallerExpanded = true
        }
    }
}

/// File and folder icons, cached because bubbles redraw often.
@MainActor
enum LensIcons {
    private static var cache: [String: NSImage] = [:]

    static func icon(for node: SpaceLensNode) -> NSImage {
        let key = node.kind == .smallerFiles ? "#smaller" : node.path
        if let cached = cache[key] { return cached }
        let image: NSImage
        switch node.kind {
        case .smallerFiles: image = NSImage(systemSymbolName: "square.grid.3x3.fill", accessibilityDescription: nil) ?? NSImage()
        case .needsAccess: image = NSImage(systemSymbolName: "lock.fill", accessibilityDescription: nil) ?? NSImage()
        default: image = NSWorkspace.shared.icon(forFile: node.path)
        }
        if cache.count > 2000 { cache.removeAll() }
        cache[key] = image
        return image
    }
}
