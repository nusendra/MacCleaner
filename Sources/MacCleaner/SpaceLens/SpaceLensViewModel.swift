import AppKit
import Foundation
import JunkCleanup
import SpaceLens

struct ScanTarget: Identifiable, Hashable {
    var name: String
    var url: URL
    var symbol: String
    var id: String { url.path }

    static var defaults: [ScanTarget] {
        [
            ScanTarget(name: "Macintosh HD", url: URL(fileURLWithPath: "/"), symbol: "internaldrive"),
            ScanTarget(name: "Home", url: JunkPaths.current.home, symbol: "house"),
        ]
    }
}

/// What the bubbles and the list show for the current folder.
struct LensLevel {
    var main: [SpaceLensNode]
    var smaller: [SpaceLensNode]
    /// Purgeable space and folders that could not be read.
    var other: [SpaceLensNode]

    var smallerSize: Int64 { smaller.reduce(0) { $0 + $1.size } }
}

@MainActor
final class SpaceLensViewModel: ObservableObject {
    enum Phase {
        case intro
        case scanning(SpaceLensProgress?)
        case results
        case removing(done: Int, total: Int)
        case finished(removed: Int64, failures: [SpaceLensRemovalResult])
    }

    @Published var target: ScanTarget = ScanTarget.defaults[1]
    @Published private(set) var targets = ScanTarget.defaults
    @Published private(set) var phase: Phase = .intro
    @Published private(set) var root: SpaceLensNode?
    @Published private(set) var current: SpaceLensNode?
    @Published private(set) var selection: [SpaceLensNode] = []
    @Published private(set) var hasFullDiskAccess = Permissions.hasFullDiskAccess
    @Published var smallerExpanded = false
    @Published var reviewing = false
    /// Bumps whenever the tree changes in place (expand, removal) so views recompute.
    @Published private(set) var revision = 0

    private var history: [SpaceLensNode] = []
    private var historyIndex = -1
    private var scanner: SpaceLensScanner?
    private var scanTask: Task<Void, Never>?

    // MARK: Scanning

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let custom = ScanTarget(name: FileManager.default.displayName(atPath: url.path), url: url, symbol: "folder")
        if !targets.contains(custom) { targets.append(custom) }
        target = custom
    }

    func scan() {
        hasFullDiskAccess = Permissions.hasFullDiskAccess
        let scanner = SpaceLensScanner(hasFullDiskAccess: hasFullDiskAccess)
        self.scanner = scanner
        phase = .scanning(nil)
        let url = target.url
        scanTask = Task {
            do {
                let tree = try await scanner.scan(url) { progress in
                    Task { @MainActor [weak self] in
                        guard let self, case .scanning = self.phase else { return }
                        self.phase = .scanning(progress)
                    }
                }
                show(tree)
            } catch {
                phase = .intro
            }
        }
    }

    func stopScan() {
        scanner?.cancel()
        scanTask?.cancel()
        phase = .intro
    }

    /// Also used by the offscreen snapshot.
    func show(_ tree: SpaceLensNode) {
        root = tree
        selection = []
        history = []
        historyIndex = -1
        navigate(to: tree)
        phase = .results
    }

    // MARK: Navigation

    var level: LensLevel {
        _ = revision
        guard let current else { return LensLevel(main: [], smaller: [], other: []) }
        let regular = current.children.filter { $0.kind != .purgeable && $0.kind != .needsAccess }
        let other = current.children.filter { $0.kind == .purgeable || $0.kind == .needsAccess }
        let (main, smaller) = BubbleLayout.split(regular) { $0.size }
        return LensLevel(main: main, smaller: smaller, other: other)
    }

    var canGoBack: Bool { history.count > 1 && historyIndex > 0 }
    var canGoForward: Bool { history.count > 1 && historyIndex < history.count - 1 }
    var canGoUp: Bool { current?.parent != nil }

    func open(_ node: SpaceLensNode) {
        guard node.isDirectory else { return }
        if node.isCollapsed, let scanner {
            Task {
                await scanner.expand(node)
                revision += 1
                navigate(to: node)
            }
        } else {
            navigate(to: node)
        }
    }

    func goUp() {
        if let parent = current?.parent { navigate(to: parent) }
    }

    func goBack() {
        guard canGoBack else { return }
        historyIndex -= 1
        current = history[historyIndex]
        smallerExpanded = false
    }

    func goForward() {
        guard canGoForward else { return }
        historyIndex += 1
        current = history[historyIndex]
        smallerExpanded = false
    }

    /// Browser-style history: navigating somewhere new drops the forward entries.
    private func navigate(to node: SpaceLensNode) {
        if let existing = history.firstIndex(where: { $0 === node }) {
            historyIndex = existing
        } else {
            if historyIndex < history.count - 1 { history.removeSubrange((historyIndex + 1)...) }
            history.append(node)
            historyIndex = history.count - 1
        }
        current = node
        smallerExpanded = false
    }

    // MARK: Selection

    func state(of node: SpaceLensNode) -> CheckState {
        if isSelected(node) { return .on }
        return selection.contains { $0.isDescendant(of: node) } ? .mixed : .off
    }

    func state(of nodes: [SpaceLensNode]) -> CheckState {
        let states = nodes.filter(\.isSelectable).map(state(of:))
        if states.isEmpty || states.allSatisfy({ $0 == .off }) { return .off }
        return states.allSatisfy { $0 == .on } ? .on : .mixed
    }

    private func isSelected(_ node: SpaceLensNode) -> Bool {
        selection.contains { $0 === node || node.isDescendant(of: $0) }
    }

    func toggle(_ node: SpaceLensNode) {
        state(of: node) == .on ? deselect(node) : select(node)
    }

    func toggle(_ nodes: [SpaceLensNode]) {
        if state(of: nodes) == .on {
            nodes.forEach(deselect)
        } else {
            nodes.filter(\.isSelectable).forEach(select)
        }
    }

    func selectAll() { current.map { toggleAll(in: $0, on: true) } }
    func deselectAll() { current.map { toggleAll(in: $0, on: false) } }

    private func toggleAll(in folder: SpaceLensNode, on: Bool) {
        for child in folder.children where child.isSelectable {
            on ? select(child) : deselect(child)
        }
    }

    private func select(_ node: SpaceLensNode) {
        guard node.isSelectable, !isSelected(node) else { return }
        selection.removeAll { $0.isDescendant(of: node) }
        selection.append(node)
    }

    /// Deselecting something inside a selected folder replaces that folder by its other parts.
    private func deselect(_ node: SpaceLensNode) {
        if let index = selection.firstIndex(where: { $0 === node }) {
            selection.remove(at: index)
            return
        }
        selection.removeAll { $0.isDescendant(of: node) }
        guard let ancestor = selection.first(where: { node.isDescendant(of: $0) }) else { return }
        selection.removeAll { $0 === ancestor }
        let path = node.lineage.drop { $0 !== ancestor }
        for (step, next) in zip(path, path.dropFirst()) {
            for sibling in step.children where sibling !== next && sibling.isSelectable {
                selection.append(sibling)
            }
        }
    }

    var plannedRemoval: [SpaceLensNode] { SpaceLensDeletionPlanner.plan(selection) }
    var selectedSize: Int64 { plannedRemoval.reduce(0) { $0 + $1.size } }
    var selectedCount: Int { plannedRemoval.count }
    var selectionTouchesCloud: Bool { plannedRemoval.contains { $0.cloud == .local } }

    // MARK: Removal

    func remove() {
        let nodes = plannedRemoval
        reviewing = false
        phase = .removing(done: 0, total: nodes.count)
        Task {
            let results = await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    let results = SpaceLensRemover.remove(nodes) { done, total in
                        Task { @MainActor [weak self] in self?.phase = .removing(done: done, total: total) }
                    }
                    continuation.resume(returning: results)
                }
            }
            var freed: Int64 = 0
            for result in results where result.succeeded {
                freed += result.node.size
                selection.removeAll { $0 === result.node || $0.isDescendant(of: result.node) || result.node.isDescendant(of: $0) }
                result.node.removeFromTree()
            }
            revision += 1
            phase = .finished(removed: freed, failures: results.filter { !$0.succeeded })
        }
    }

    func backToResults() { phase = .results }

    func startOver() {
        root = nil
        current = nil
        selection = []
        phase = .intro
    }

    func reveal(_ node: SpaceLensNode) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: node.memberPaths.first ?? node.path)])
    }

    func openFullDiskAccessSettings() { NSWorkspace.shared.open(Permissions.fullDiskAccessSettingsURL) }

    // MARK: Disk usage

    struct DiskUsage {
        var total: Int64
        var used: Int64
        var purgeable: Int64
    }

    var diskUsage: DiskUsage? {
        guard let root else { return nil }
        let keys: Set<URLResourceKey> = [.volumeTotalCapacityKey, .volumeAvailableCapacityKey]
        guard let values = try? root.url.resourceValues(forKeys: keys),
              let total = values.volumeTotalCapacity, let available = values.volumeAvailableCapacity
        else { return nil }
        let purgeable = root.children.first { $0.kind == .purgeable }?.size ?? 0
        return DiskUsage(total: Int64(total), used: Int64(total - available), purgeable: purgeable)
    }
}
