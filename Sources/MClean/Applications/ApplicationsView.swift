import AppKit
import AppUninstaller
import SwiftUI

struct ApplicationsView: View {
    @StateObject private var viewModel: ApplicationsViewModel

    init(section: AppsSection) {
        _viewModel = StateObject(wrappedValue: ApplicationsViewModel(section: section))
    }

    var body: some View {
        Group {
            switch viewModel.phase {
            case .loading:
                VStack(spacing: 12) {
                    ProgressView()
                    Text("Looking for applications and leftovers…").foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .ready:
                content
            case .removing(let done, let total):
                VStack(spacing: 12) {
                    ProgressView(value: Double(done), total: Double(max(total, 1))).frame(maxWidth: 360)
                    Text("Uninstalling… \(done) of \(total)").foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .finished(let results):
                RemovalResultsView(results: results) { viewModel.dismissResults() }
            }
        }
        .navigationTitle(viewModel.section == .leftovers ? "Leftovers" : "Uninstaller")
        .task { if case .loading = viewModel.phase { viewModel.load() } }
        .confirmationDialog(confirmTitle, isPresented: $viewModel.confirmingRemoval, titleVisibility: .visible) {
            Button("Move to Trash", role: .destructive) { viewModel.remove() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("\(viewModel.selectedSize.formattedBytes) will be moved to the Trash. Preferences are also cleared from the system's settings cache, and launch agents are stopped.")
        }
        .sheet(item: $viewModel.runningConflict) { conflict in
            QuitAppsSheet(conflict: conflict, viewModel: viewModel)
        }
    }

    private var confirmTitle: String {
        let apps = viewModel.selectedAppCount
        let items = viewModel.selectedPairs.count
        return "Remove \(items) \(items == 1 ? "item" : "items") from \(apps) \(apps == 1 ? "app" : "apps")?"
    }

    private var content: some View {
        VStack(spacing: 0) {
            if !viewModel.hasFullDiskAccess {
                FullDiskAccessBanner(viewModel: viewModel)
                Divider()
            }
            HSplitView {
                AppListPane(viewModel: viewModel)
                    .frame(minWidth: 280, idealWidth: 320, maxWidth: 420)
                AppDetailPane(viewModel: viewModel)
                    .frame(minWidth: 360, maxWidth: .infinity)
            }
            Divider()
            HStack {
                Text(viewModel.selectedPairs.isEmpty ? "Nothing selected" : "\(viewModel.selectedSize.formattedBytes) selected in \(viewModel.selectedAppCount) \(viewModel.selectedAppCount == 1 ? "app" : "apps")")
                    .foregroundStyle(.secondary)
                Spacer()
                Button(viewModel.section == .leftovers ? "Remove" : "Uninstall") { viewModel.requestRemoval() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(viewModel.selectedPairs.isEmpty)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
    }
}

// MARK: List

private struct AppListPane: View {
    @ObservedObject var viewModel: ApplicationsViewModel

    var body: some View {
        VStack(spacing: 8) {
            Picker("Section", selection: $viewModel.section) {
                ForEach(AppsSection.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 12)
            .padding(.top, 12)

            HStack(spacing: 8) {
                TextField("Search", text: $viewModel.search)
                    .textFieldStyle(.roundedBorder)
                if viewModel.section == .applications {
                    Menu {
                        Picker("Show", selection: $viewModel.filter) {
                            ForEach(filters, id: \.self) { Text($0.title).tag($0) }
                        }
                        .pickerStyle(.inline)
                    } label: {
                        Image(systemName: "line.3.horizontal.decrease.circle")
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .accessibilityLabel("Filter")
                }
                Menu {
                    Picker("Sort by", selection: $viewModel.sort) {
                        ForEach(AppsSort.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.inline)
                } label: {
                    Image(systemName: "arrow.up.arrow.down.circle")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .accessibilityLabel("Sort")
            }
            .padding(.horizontal, 12)

            if viewModel.section == .applications, viewModel.filter != .all {
                Text(viewModel.filter.title).font(.caption).foregroundStyle(.secondary)
            }

            let apps = viewModel.visibleApps
            if apps.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: viewModel.section == .leftovers ? "checkmark.seal" : "magnifyingglass")
                        .font(.largeTitle)
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                    Text(viewModel.section == .leftovers ? "No leftovers found" : "No apps match")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(apps, selection: $viewModel.focusedID) { app in
                    AppRow(app: app, viewModel: viewModel).tag(app.id)
                }
                .listStyle(.inset)
            }
        }
    }

    private var filters: [AppsFilter] {
        [.all, .unused, .appStore, .system] + AppVendor.allCases.map { .vendor($0) }
    }
}

private struct AppRow: View {
    let app: InstalledApplication
    @ObservedObject var viewModel: ApplicationsViewModel

    var body: some View {
        HStack(spacing: 10) {
            CheckBox(state: viewModel.appState(app), label: "Select \(app.displayName)") { viewModel.toggle(app: app) }
            AppIcon(app: app, size: 28)
            VStack(alignment: .leading, spacing: 1) {
                Text(app.displayName).lineLimit(1)
                Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            if let size = viewModel.sizes[app.id] {
                Text(size.formattedBytes).monospacedDigit().foregroundStyle(.secondary)
            } else {
                ProgressView().controlSize(.mini)
            }
        }
        .padding(.vertical, 2)
        .contextMenu {
            if let url = app.url { Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) } }
            if app.bundleIdentifier != nil { Button("Ignore in Future Scans") { viewModel.ignore(app) } }
        }
    }

    private var subtitle: String {
        if app.isLeftover { return app.bundleIdentifier ?? "" }
        if app.isUnused(), let date = app.lastUsed { return "Last opened \(date.formatted(.relative(presentation: .named)))" }
        return [app.version, app.store == .other ? nil : app.store.rawValue].compactMap { $0 }.joined(separator: " · ")
    }
}

struct AppIcon: View {
    let app: InstalledApplication
    let size: CGFloat

    var body: some View {
        Group {
            if let url = app.url {
                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable()
            } else {
                Image(systemName: "questionmark.app.dashed").resizable().foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

// MARK: Detail

private struct AppDetailPane: View {
    @ObservedObject var viewModel: ApplicationsViewModel

    var body: some View {
        if let app = viewModel.focusedApp {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    header(app)
                    if let resources = viewModel.resources[app.id] {
                        if resources.isEmpty {
                            Text("No files found.").foregroundStyle(.secondary)
                        }
                        if let skipped = viewModel.skippedLocations[app.id], !skipped.isEmpty {
                            Label("Not checked (no answer in time): \(skipped.joined(separator: ", ")). macOS may be waiting for you to allow access.", systemImage: "exclamationmark.triangle")
                                .font(.callout)
                                .foregroundStyle(.orange)
                        }
                        ForEach(ResourceGroup.allCases, id: \.self) { group in
                            let items = resources.filter { $0.group == group }
                            if !items.isEmpty { GroupSection(app: app, group: group, items: items, viewModel: viewModel) }
                        }
                    } else {
                        LoadingFilesView().id(app.id)
                    }
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onAppear { viewModel.loadResources(for: app) }
            .onChange(of: viewModel.focusedID) { _, _ in
                if let focused = viewModel.focusedApp { viewModel.loadResources(for: focused) }
            }
        } else {
            Text("Select an app to see its files").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func header(_ app: InstalledApplication) -> some View {
        HStack(spacing: 14) {
            AppIcon(app: app, size: 56)
            VStack(alignment: .leading, spacing: 3) {
                Text(app.displayName).font(.title2.weight(.semibold))
                Text([app.bundleIdentifier, app.version.map { "Version \($0)" }].compactMap { $0 }.joined(separator: " · "))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                if app.isSystem {
                    Label("System app: its files can be removed to reset it.", systemImage: "lock")
                        .font(.caption).foregroundStyle(.orange)
                } else if app.isAppStore {
                    Label("App Store app: remove it in Launchpad. Its files can be removed here.", systemImage: "bag")
                        .font(.caption).foregroundStyle(.secondary)
                } else if app.isLeftover {
                    Label("The app is gone; these files were left behind.", systemImage: "shippingbox")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }
}

private struct GroupSection: View {
    let app: InstalledApplication
    let group: ResourceGroup
    let items: [AppResource]
    @ObservedObject var viewModel: ApplicationsViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                CheckBox(state: viewModel.groupState(group, of: app), label: "Select \(group.rawValue)") { viewModel.toggle(group: group, of: app) }
                    .disabled(!items.contains(where: \.isRemovable))
                Image(systemName: group.symbol).foregroundStyle(Color.accentColor).frame(width: 18).accessibilityHidden(true)
                Text(group.rawValue).font(.headline)
                Spacer()
                Text(items.reduce(0) { $0 + $1.size }.formattedBytes).monospacedDigit().foregroundStyle(.secondary)
            }
            ForEach(items) { item in
                HStack(spacing: 8) {
                    CheckBox(state: viewModel.isSelected(item, of: app) ? .on : .off, label: "Select \(item.displayName)") { viewModel.toggle(item, of: app) }
                        .disabled(!item.isRemovable)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(item.displayName).lineLimit(1).truncationMode(.middle)
                        Text(item.note ?? abbreviated(item.path)).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    }
                    Spacer()
                    Text(item.size.formattedBytes).monospacedDigit().foregroundStyle(.secondary)
                }
                .padding(.leading, 26)
                .opacity(item.isRemovable ? 1 : 0.55)
                .help(item.path)
                .contextMenu {
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([item.url]) }
                }
            }
        }
        .padding(12)
        .background(.background, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.secondary.opacity(0.15)))
    }

    private func abbreviated(_ path: String) -> String {
        path.replacingOccurrences(of: NSHomeDirectory(), with: "~")
    }
}

/// Spinner that explains itself if the scan takes unusually long.
private struct LoadingFilesView: View {
    @State private var slow = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                ProgressView().controlSize(.small)
                Text("Finding related files…").foregroundStyle(.secondary)
            }
            if slow {
                Text("This is taking longer than usual. If macOS asked for permission to access files, answer that prompt; results appear within 15 seconds either way.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .task {
            try? await Task.sleep(for: .seconds(4))
            slow = true
        }
    }
}

private struct FullDiskAccessBanner: View {
    @ObservedObject var viewModel: ApplicationsViewModel

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "lock.shield")
                .font(.title2)
                .foregroundStyle(.orange)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("Limited access").font(.headline)
                Text("Without Full Disk Access, other apps' containers are listed without sizes and downloaded installers are skipped. Grant it to the app you start MClean from (for example Terminal), then check again.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Button("Open Settings") { viewModel.openFullDiskAccessSettings() }
            Button("Check Again") { viewModel.refreshPermissions() }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .background(Color.orange.opacity(0.08))
    }
}

// MARK: Sheets

private struct QuitAppsSheet: View {
    let conflict: ApplicationsViewModel.RunningConflict
    @ObservedObject var viewModel: ApplicationsViewModel
    @State private var quitting = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Some applications should be quit").font(.title3.weight(.semibold))
            Text("Quit these apps so all of their files can be removed:").foregroundStyle(.secondary)
            ForEach(conflict.apps, id: \.processIdentifier) { app in
                HStack {
                    if let icon = app.icon { Image(nsImage: icon).resizable().frame(width: 24, height: 24).accessibilityHidden(true) }
                    Text(app.localizedName ?? app.bundleIdentifier ?? "App")
                }
            }
            HStack {
                Button("Skip These Apps") { viewModel.skip(conflict) }
                Spacer()
                if viewModel.forceQuitAvailable {
                    Button("Force Quit", role: .destructive) { viewModel.forceQuit(conflict) }
                }
                Button(quitting ? "Quitting…" : "Quit All") {
                    quitting = true
                    viewModel.quit(conflict)
                }
                .buttonStyle(.borderedProminent)
                .disabled(quitting && !viewModel.forceQuitAvailable)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 420)
    }
}

private struct RemovalResultsView: View {
    let results: [UninstallResult]
    let onDone: () -> Void

    var body: some View {
        let failures = results.filter { !$0.succeeded }
        let freed = results.filter(\.succeeded).reduce(Int64(0)) { $0 + $1.resource.size }
        VStack(spacing: 14) {
            Image(systemName: failures.isEmpty ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .font(.system(size: 52))
                .foregroundStyle(failures.isEmpty ? Color.green : Color.orange)
                .accessibilityHidden(true)
            Text(failures.isEmpty ? "Done" : "Some files were not removed").font(.title.weight(.semibold))
            Text("\(freed.formattedBytes) moved to the Trash. Empty the Trash to free the space.")
                .foregroundStyle(.secondary)
            if !failures.isEmpty {
                List(failures) { failure in
                    VStack(alignment: .leading) {
                        Text(failure.resource.displayName)
                        Text(failure.error ?? "").font(.caption).foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: 520, maxHeight: 220)
            }
            HStack {
                Button("Open Trash") { NSWorkspace.shared.open(FileManager.default.homeDirectoryForCurrentUser.appending(path: ".Trash")) }
                Button("Done", action: onDone).buttonStyle(.borderedProminent)
            }
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
