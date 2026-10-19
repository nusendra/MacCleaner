import AppKit
import AppUninstaller
import Foundation
import JunkCleanup

enum AppsSection: String, CaseIterable, Identifiable, Hashable {
    case applications = "Applications"
    case leftovers = "Leftovers"
    var id: String { rawValue }
}

enum AppsFilter: Hashable {
    case all, unused, appStore, system, vendor(AppVendor)

    var title: String {
        switch self {
        case .all: "All Applications"
        case .unused: "Unused (6+ months)"
        case .appStore: "App Store"
        case .system: "System (reset only)"
        case .vendor(let vendor): vendor.rawValue
        }
    }
}

enum AppsSort: String, CaseIterable, Identifiable {
    case name = "Name", size = "Size", lastOpened = "Last Opened"
    var id: String { rawValue }
}

@MainActor
final class ApplicationsViewModel: ObservableObject {
    enum Phase {
        case loading
        case ready
        case removing(done: Int, total: Int)
        case finished([UninstallResult])
    }

    struct RunningConflict: Identifiable {
        var apps: [NSRunningApplication]
        var id: String { apps.map { "\($0.processIdentifier)" }.joined(separator: ",") }
        var names: String { apps.compactMap(\.localizedName).joined(separator: ", ") }
    }

    @Published var section: AppsSection
    @Published var filter: AppsFilter = .all
    @Published var sort: AppsSort = .name
    @Published var search = ""
    @Published var focusedID: String?
    @Published private(set) var phase: Phase = .loading
    @Published private(set) var apps: [InstalledApplication] = []
    @Published private(set) var leftovers: [InstalledApplication] = []
    @Published private(set) var sizes: [String: Int64] = [:]
    @Published private(set) var resources: [String: [AppResource]] = [:]
    /// Selected resource keys (`appID|resourceID`).
    @Published var selection: Set<String> = []
    @Published var confirmingRemoval = false
    @Published var runningConflict: RunningConflict?
    @Published var forceQuitAvailable = false

    private var loadingResources: Set<String> = []

    init(section: AppsSection) {
        self.section = section
    }

    // MARK: Loading

    func load() {
        phase = .loading
        Task {
            let (apps, leftovers) = await Task.detached(priority: .userInitiated) { () -> ([InstalledApplication], [InstalledApplication]) in
                let home = JunkPaths.current.home
                let apps = ApplicationDiscovery.installedApplications(home: home)
                let installed = ApplicationDiscovery.installedBundleIdentifiers(apps: apps, home: home)
                let leftovers = LeftoversScanner().candidates(installedIDs: installed)
                    .map { InstalledApplication(leftoverBundleID: $0.bundleID, name: $0.name) }
                return (apps, leftovers)
            }.value
            self.apps = apps
            self.leftovers = leftovers
            self.phase = .ready
            self.focusedID = self.visibleApps.first?.id
            self.measureBundles()
            // Leftovers have no bundle, so their size is the size of their files: load them all up front.
            leftovers.forEach { self.loadResources(for: $0) }
        }
    }

    /// Bundle sizes for the list, computed in the background a few apps at a time.
    private func measureBundles() {
        let targets = apps.compactMap { app in app.url.map { (app.id, $0) } }
        // Child tasks size bundles off the main actor; results are applied here as they arrive.
        Task(priority: .utility) {
            await withTaskGroup(of: (String, Int64).self) { group in
                var iterator = targets.makeIterator()
                for _ in 0..<4 { if let (id, url) = iterator.next() { group.addTask { (id, FileSizer.allocatedSize(of: url)) } } }
                for await (id, size) in group {
                    sizes[id] = size
                    if let (id, url) = iterator.next() { group.addTask { (id, FileSizer.allocatedSize(of: url)) } }
                }
            }
        }
    }

    func loadResources(for app: InstalledApplication) {
        guard resources[app.id] == nil, loadingResources.insert(app.id).inserted else { return }
        Task {
            let found = await Task.detached(priority: .userInitiated) { AppResourcesScanner().resources(for: app) }.value
            self.resources[app.id] = found
            self.loadingResources.remove(app.id)
            if app.isLeftover { self.sizes[app.id] = found.reduce(0) { $0 + $1.size } }
        }
    }

    // MARK: List

    var visibleApps: [InstalledApplication] {
        var list = section == .leftovers ? leftovers : apps
        if section == .applications {
            switch filter {
            case .all: list = list.filter { !$0.isSystem }
            case .unused: list = list.filter { $0.isUnused() && !$0.isSystem }
            case .appStore: list = list.filter(\.isAppStore)
            case .system: list = list.filter(\.isSystem)
            case .vendor(let vendor): list = list.filter { $0.vendor == vendor && !$0.isSystem }
            }
        }
        if !search.isEmpty {
            list = list.filter { $0.displayName.localizedCaseInsensitiveContains(search) || ($0.bundleIdentifier ?? "").localizedCaseInsensitiveContains(search) }
        }
        switch sort {
        case .name: return list.sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
        case .size: return list.sorted { (sizes[$0.id] ?? 0) > (sizes[$1.id] ?? 0) }
        case .lastOpened: return list.sorted { ($0.lastUsed ?? .distantPast) < ($1.lastUsed ?? .distantPast) }
        }
    }

    var focusedApp: InstalledApplication? {
        (apps + leftovers).first { $0.id == focusedID }
    }

    func app(withID id: String) -> InstalledApplication? {
        (apps + leftovers).first { $0.id == id }
    }

    // MARK: Selection

    private func key(_ app: InstalledApplication, _ resource: AppResource) -> String { "\(app.id)|\(resource.id)" }

    func isSelected(_ resource: AppResource, of app: InstalledApplication) -> Bool { selection.contains(key(app, resource)) }

    func toggle(_ resource: AppResource, of app: InstalledApplication) {
        let k = key(app, resource)
        if selection.contains(k) { selection.remove(k) } else if resource.isRemovable { selection.insert(k) }
    }

    func toggle(group: ResourceGroup, of app: InstalledApplication) {
        let items = (resources[app.id] ?? []).filter { $0.group == group && $0.isRemovable }
        let keys = items.map { key(app, $0) }
        if keys.allSatisfy(selection.contains) { selection.subtract(keys) } else { selection.formUnion(keys) }
    }

    func groupState(_ group: ResourceGroup, of app: InstalledApplication) -> CheckState {
        state(of: (resources[app.id] ?? []).filter { $0.group == group && $0.isRemovable }.map { key(app, $0) })
    }

    func appState(_ app: InstalledApplication) -> CheckState {
        state(of: (resources[app.id] ?? []).filter(\.isRemovable).map { key(app, $0) })
    }

    private func state(of keys: [String]) -> CheckState {
        let selected = keys.filter(selection.contains).count
        if selected == 0 || keys.isEmpty { return .off }
        return selected == keys.count ? .on : .mixed
    }

    /// Checking an app selects everything removable once its files are known.
    func toggle(app: InstalledApplication) {
        guard let found = resources[app.id] else {
            loadResources(for: app)
            pendingSelection.insert(app.id)
            Task { await self.applyPendingSelection(for: app) }
            return
        }
        let keys = found.filter(\.isRemovable).map { key(app, $0) }
        if appState(app) == .on { selection.subtract(keys) } else { selection.formUnion(keys) }
    }

    private var pendingSelection: Set<String> = []

    private func applyPendingSelection(for app: InstalledApplication) async {
        while resources[app.id] == nil { try? await Task.sleep(for: .milliseconds(50)) }
        guard pendingSelection.remove(app.id) != nil else { return }
        selection.formUnion((resources[app.id] ?? []).filter(\.isRemovable).map { key(app, $0) })
    }

    var selectedPairs: [(InstalledApplication, AppResource)] {
        (apps + leftovers).flatMap { app in
            (resources[app.id] ?? []).filter { selection.contains(key(app, $0)) }.map { (app, $0) }
        }
    }

    var selectedSize: Int64 { selectedPairs.reduce(0) { $0 + $1.1.size } }
    var selectedAppCount: Int { Set(selectedPairs.map(\.0.id)).count }

    func ignore(_ app: InstalledApplication) {
        if let id = app.bundleIdentifier { IgnoreList.shared.add(id) }
        selection = selection.filter { !$0.hasPrefix(app.id + "|") }
        leftovers.removeAll { $0.id == app.id }
    }

    // MARK: Removal

    /// Running apps whose bundle is selected must be quit first.
    func requestRemoval() {
        let bundles = Set(selectedPairs.filter { $0.1.group == .binaries }.compactMap { $0.0.bundleIdentifier })
        let running = NSWorkspace.shared.runningApplications.filter { app in
            guard let id = app.bundleIdentifier else { return false }
            return bundles.contains(id) && app.processIdentifier != ProcessInfo.processInfo.processIdentifier
        }
        if running.isEmpty {
            confirmingRemoval = true
        } else {
            forceQuitAvailable = false
            runningConflict = RunningConflict(apps: running)
        }
    }

    /// Graceful quit; Force Quit is offered after 5 seconds, as in CleanMyMac's terminator.
    func quit(_ conflict: RunningConflict) {
        conflict.apps.forEach { $0.terminate() }
        Task {
            for tick in 0..<100 {
                if conflict.apps.allSatisfy(\.isTerminated) {
                    runningConflict = nil
                    confirmingRemoval = true
                    return
                }
                if tick == 50 { forceQuitAvailable = true }
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }

    func forceQuit(_ conflict: RunningConflict) {
        conflict.apps.forEach { $0.forceTerminate() }
        quit(conflict)
    }

    func skip(_ conflict: RunningConflict) {
        let ids = Set(conflict.apps.compactMap(\.bundleIdentifier))
        let skipped = Set((apps + leftovers).filter { ids.contains($0.bundleIdentifier ?? "") }.map(\.id))
        selection = selection.filter { key in !skipped.contains { key.hasPrefix($0 + "|") } }
        runningConflict = nil
        if !selectedPairs.isEmpty { confirmingRemoval = true }
    }

    func remove() {
        let pairs = selectedPairs
        phase = .removing(done: 0, total: pairs.count)
        Task {
            let results = await Task.detached(priority: .userInitiated) {
                await Uninstaller().remove(pairs.map(\.1)) { done, total in
                    Task { @MainActor [weak self] in self?.phase = .removing(done: done, total: total) }
                }
            }.value
            self.apply(results, removedFrom: pairs)
            self.phase = .finished(results)
        }
    }

    private func apply(_ results: [UninstallResult], removedFrom pairs: [(InstalledApplication, AppResource)]) {
        let removed = Set(results.filter(\.succeeded).map(\.resource.id))
        for (app, resource) in pairs where removed.contains(resource.id) {
            resources[app.id]?.removeAll { $0.id == resource.id }
            selection.remove(key(app, resource))
            if resource.group == .binaries { apps.removeAll { $0.id == app.id } }
        }
        leftovers.removeAll { resources[$0.id]?.isEmpty == true }
        if let focusedID, app(withID: focusedID) == nil { self.focusedID = visibleApps.first?.id }
    }

    func dismissResults() {
        phase = .ready
    }
}
