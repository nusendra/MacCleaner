import AppKit
import Foundation
import JunkCleanup

/// Which groups a flow shows: the full System Junk module, or only the Trash Bins.
enum JunkFlow: Hashable {
    case systemJunk
    case trashBins

    var title: String {
        switch self {
        case .systemJunk: "System Junk"
        case .trashBins: "Trash Bins"
        }
    }

    var tasks: [any JunkScanTask] {
        JunkScanTasks.all().filter { task in
            switch self {
            case .systemJunk: task.group.category == .systemJunk
            case .trashBins: task.group == .trashes
            }
        }
    }
}

enum CheckState {
    case on, off, mixed
}

@MainActor
final class SystemJunkViewModel: ObservableObject {
    enum Phase {
        case intro
        case scanning(JunkScanProgress?)
        case results
        case cleaning(done: Int, total: Int, current: String)
        case cleaned(JunkCleanReport)
    }

    struct QuitConflict: Identifiable {
        var apps: [NSRunningApplication]
        var items: [JunkItem]
        var id: String { apps.map { $0.bundleIdentifier ?? "" }.joined() }
        var names: String { apps.compactMap(\.localizedName).joined(separator: ", ") }
    }

    let flow: JunkFlow
    @Published private(set) var phase: Phase = .intro
    @Published private(set) var groups: [JunkGroup] = []
    @Published private(set) var failures: [String: String] = [:]
    @Published var selection: Set<String> = []
    @Published var confirmingClean = false
    @Published var quitConflict: QuitConflict?

    private var scanTask: Task<Void, Never>?
    private var cleanTask: Task<Void, Never>?
    private var cleanWorker: Task<JunkCleanReport, Never>?

    init(flow: JunkFlow) {
        self.flow = flow
    }

    // MARK: Scanning

    func scan() {
        scanTask?.cancel()
        phase = .scanning(nil)
        let scanner = JunkScanner(tasks: flow.tasks)
        scanTask = Task { [weak self] in
            let result = await scanner.scan { progress in
                Task { @MainActor in
                    guard let self, case .scanning = self.phase else { return }
                    self.phase = .scanning(progress)
                }
            }
            guard let self, !Task.isCancelled else { return }
            self.groups = result.groups
            self.failures = result.failures
            self.selection = Set(result.allItems.filter(\.isAutoSelected).map(\.id))
            self.phase = .results
        }
    }

    func stopScan() {
        scanTask?.cancel()
        phase = .intro
    }

    // MARK: Selection

    var allItems: [JunkItem] { groups.flatMap(\.items) }
    var totalSize: Int64 { groups.reduce(0) { $0 + $1.size } }
    var selectedItems: [JunkItem] { allItems.filter { selection.contains($0.id) } }
    var selectedSize: Int64 { selectedItems.reduce(0) { $0 + $1.size } }

    func state(of items: [JunkItem]) -> CheckState {
        let selected = items.filter { selection.contains($0.id) }.count
        if selected == 0 { return .off }
        return selected == items.count ? .on : .mixed
    }

    func toggle(_ items: [JunkItem]) {
        let ids = items.map(\.id)
        if state(of: items) == .on {
            selection.subtract(ids)
        } else {
            selection.formUnion(ids)
        }
    }

    /// Hides an item or a whole owner from future scans and drops it from the current results.
    func ignore(path: String, removing ids: Set<String>) {
        IgnoreList.shared.add(path)
        remove(ids)
    }

    private func remove(_ ids: Set<String>) {
        selection.subtract(ids)
        groups = groups.compactMap { group in
            var group = group
            group.subgroups = group.subgroups.compactMap { subgroup in
                var subgroup = subgroup
                subgroup.items.removeAll { ids.contains($0.id) }
                return subgroup.items.isEmpty ? nil : subgroup
            }
            return group.subgroups.isEmpty ? nil : group
        }
    }

    var selectionIncludesLatestBackup: Bool {
        selectedItems.contains { $0.detail == "Latest backup" }
    }

    // MARK: Cleaning

    /// Apps that own selected items must be quit first; otherwise they recreate or hold the files.
    func requestClean() {
        let required = Set(selectedItems.flatMap(\.quitBeforeCleaning))
        let running = NSWorkspace.shared.runningApplications.filter { app in
            guard let id = app.bundleIdentifier else { return false }
            return required.contains(id) && app.processIdentifier != ProcessInfo.processInfo.processIdentifier
        }
        if running.isEmpty {
            confirmingClean = true
        } else {
            let runningIDs = Set(running.compactMap(\.bundleIdentifier))
            quitConflict = QuitConflict(apps: running, items: selectedItems.filter { !$0.quitBeforeCleaning.isDisjoint(with: runningIDs) })
        }
    }

    func quitAppsThenConfirm(_ conflict: QuitConflict) {
        conflict.apps.forEach { $0.terminate() }
        Task {
            for _ in 0..<50 where conflict.apps.contains(where: { !$0.isTerminated }) {
                try? await Task.sleep(for: .milliseconds(100))
            }
            if conflict.apps.contains(where: { !$0.isTerminated }) {
                skipItems(of: conflict)
            } else {
                confirmingClean = true
            }
        }
    }

    func skipItems(of conflict: QuitConflict) {
        selection.subtract(conflict.items.map(\.id))
        if !selectedItems.isEmpty { confirmingClean = true }
    }

    /// Removal does blocking file I/O, so it runs detached; the handle is kept so Stop can cancel it.
    func clean() {
        let items = selectedItems
        phase = .cleaning(done: 0, total: items.count, current: "")
        let worker = Task.detached(priority: .userInitiated) { [weak self] in
            await JunkCleaner().clean(items) { done, total, item in
                Task { @MainActor in
                    guard let self, case .cleaning = self.phase else { return }
                    self.phase = .cleaning(done: done, total: total, current: item.name)
                }
            }
        }
        cleanTask = Task { [weak self] in
            let report = await worker.value
            guard let self else { return }
            self.remove(Set(report.results.filter(\.succeeded).map(\.id)))
            self.phase = .cleaned(report)
        }
        cleanWorker = worker
    }

    func stopCleaning() {
        cleanWorker?.cancel()
    }

    func reviewRemaining() {
        phase = groups.isEmpty ? .intro : .results
    }
}

extension Int64 {
    var formattedBytes: String { ByteCountFormatter.string(fromByteCount: self, countStyle: .file) }
}
