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

    @Published private(set) var skippedLocations: [String: [String]] = [:]
    @Published private(set) var pendingSelection: Set<String> = []
    @Published private(set) var hasFullDiskAccess = Permissions.hasFullDiskAccess

    private var loadingResources: Set<String> = []
    private var scanner: AppResourcesScanner?
    /// Background prefetch (leftover sizes) runs two at a time so it never crowds out what the user clicked.
    private let prefetchQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 2
        queue.qualityOfService = .utility
        return queue
    }()

    private let sizingQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 3
        queue.qualityOfService = .utility
        return queue
    }()

    init(section: AppsSection) {
        self.section = section
    }

    // MARK: Loading

    func load() {
        phase = .loading
        hasFullDiskAccess = Permissions.hasFullDiskAccess
        Task {
            let (apps, leftovers, scanner) = await Self.offMain { () -> ([InstalledApplication], [InstalledApplication], AppResourcesScanner) in
                let home = JunkPaths.current.home
                let apps = ApplicationDiscovery.installedApplications(home: home)
                let installed = ApplicationDiscovery.installedBundleIdentifiers(apps: apps, home: home)
                let leftovers = LeftoversScanner().candidates(installedIDs: installed)
                    .map { InstalledApplication(leftoverBundleID: $0.bundleID, name: $0.name) }
                return (apps, leftovers, AppResourcesScanner())
            }
            self.scanner = scanner
            self.apps = apps
            self.leftovers = leftovers
            self.phase = .ready
            self.focusedID = self.visibleApps.first?.id
            if let focused = self.focusedApp { self.loadResources(for: focused) }
            self.measureBundles()
            // Leftovers have no bundle, so their size is the size of their files: prefetch them in the background.
            leftovers.forEach { self.loadResources(for: $0, background: true) }
        }
    }

    /// Runs blocking file-system work on a GCD queue instead of Swift's small cooperative thread pool,
    /// so a slow or blocked read can never starve the rest of the app.
    nonisolated static func offMain<T: Sendable>(qos: DispatchQoS.QoSClass = .userInitiated, _ work: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: qos).async { continuation.resume(returning: work()) }
        }
    }

    /// Bundle sizes for the list, computed in the background a few apps at a time.
    private func measureBundles() {
        for app in apps {
            guard let url = app.url else { continue }
            let id = app.id
            sizingQueue.addOperation {
                let size = FileSizer.allocatedSize(of: url)
                Task { @MainActor [weak self] in self?.sizes[id] = size }
            }
        }
    }

    func loadResources(for app: InstalledApplication, background: Bool = false) {
        guard let scanner, resources[app.id] == nil, loadingResources.insert(app.id).inserted else { return }
        let finish: @Sendable (AppResourcesScanner.Scan) -> Void = { scan in
            Task { @MainActor [weak self] in self?.apply(scan, for: app) }
        }
        if background {
            prefetchQueue.addOperation { finish(scanner.scan(app)) }
        } else {
            DispatchQueue.global(qos: .userInitiated).async { finish(scanner.scan(app)) }
        }
    }

    private func apply(_ scan: AppResourcesScanner.Scan, for app: InstalledApplication) {
        guard resources[app.id] == nil else { return }
        resources[app.id] = scan.resources
        skippedLocations[app.id] = scan.skippedLocations
        loadingResources.remove(app.id)
        if app.isLeftover { sizes[app.id] = scan.resources.reduce(0) { $0 + $1.size } }
        // A checkbox clicked before the files were known selects them now.
        if pendingSelection.remove(app.id) != nil {
            selection.formUnion(scan.resources.filter(\.isRemovable).map { key(app, $0) })
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
        if pendingSelection.contains(app.id) { return .on }
        return state(of: (resources[app.id] ?? []).filter(\.isRemovable).map { key(app, $0) })
    }

    private func state(of keys: [String]) -> CheckState {
        let selected = keys.filter(selection.contains).count
        if selected == 0 || keys.isEmpty { return .off }
        return selected == keys.count ? .on : .mixed
    }

    /// Checking an app selects everything removable; if its files are still loading, the box shows checked
    /// right away and the selection is applied when they arrive.
    func toggle(app: InstalledApplication) {
        guard let found = resources[app.id] else {
            if pendingSelection.remove(app.id) == nil {
                pendingSelection.insert(app.id)
                loadResources(for: app)
            }
            return
        }
        let keys = found.filter(\.isRemovable).map { key(app, $0) }
        if appState(app) == .on { selection.subtract(keys) } else { selection.formUnion(keys) }
    }

    func isLoading(_ app: InstalledApplication) -> Bool { resources[app.id] == nil }

    func openFullDiskAccessSettings() {
        NSWorkspace.shared.open(Permissions.fullDiskAccessSettingsURL)
    }

    func refreshPermissions() {
        let granted = Permissions.hasFullDiskAccess
        guard granted != hasFullDiskAccess else { return }
        hasFullDiskAccess = granted
        load() // rescan so containers and Downloads are included
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
