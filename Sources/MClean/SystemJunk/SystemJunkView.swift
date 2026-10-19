import JunkCleanup
import SwiftUI

struct SystemJunkView: View {
    @StateObject private var viewModel: SystemJunkViewModel

    init(flow: JunkFlow) {
        _viewModel = StateObject(wrappedValue: SystemJunkViewModel(flow: flow))
    }

    var body: some View {
        Group {
            switch viewModel.phase {
            case .intro: intro
            case .scanning(let progress): scanning(progress)
            case .results: results
            case .cleaning(let done, let total, let current): cleaning(done: done, total: total, current: current)
            case .cleaned(let report): cleaned(report)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle(viewModel.flow.title)
        .confirmationDialog(confirmTitle, isPresented: $viewModel.confirmingClean, titleVisibility: .visible) {
            Button("Delete \(viewModel.selectedSize.formattedBytes)", role: .destructive) { viewModel.clean() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(confirmMessage)
        }
        .alert(item: $viewModel.quitConflict) { conflict in
            Alert(
                title: Text("Quit \(conflict.names) first?"),
                message: Text("These apps use some of the selected files. Quit them to clean everything, or skip their \(conflict.items.count) items."),
                primaryButton: .default(Text("Quit and Clean")) { viewModel.quitAppsThenConfirm(conflict) },
                secondaryButton: .cancel(Text("Skip Their Items")) { viewModel.skipItems(of: conflict) }
            )
        }
    }

    private var confirmTitle: String {
        let count = viewModel.selectedItems.count
        return "Permanently delete \(count) \(count == 1 ? "item" : "items")?"
    }

    private var confirmMessage: String {
        var message = "This frees \(viewModel.selectedSize.formattedBytes). Deleted files do not go to the Trash and cannot be recovered."
        if viewModel.selectionIncludesLatestBackup {
            message += "\n\nThe selection includes the latest backup of a device."
        }
        return message
    }

    // MARK: Phases

    private var intro: some View {
        VStack(spacing: 16) {
            Image(systemName: viewModel.flow == .trashBins ? "trash" : "sparkles")
                .font(.system(size: 56))
                .foregroundStyle(Color.accentColor)
                .accessibilityHidden(true)
            Text(viewModel.flow.title)
                .font(.largeTitle.weight(.semibold))
            Text(viewModel.flow == .trashBins
                 ? "Empty the Trash on your Mac, iCloud Drive and external drives."
                 : "Find caches, logs, broken preferences, Xcode leftovers and other files your Mac no longer needs.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 420)
            Button("Scan") { viewModel.scan() }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
        }
        .padding(32)
    }

    private func scanning(_ progress: JunkScanProgress?) -> some View {
        VStack(spacing: 16) {
            ProgressView(value: progress?.fraction ?? 0)
                .frame(maxWidth: 360)
            Text(progress.map { "Scanned \($0.currentTitle.lowercased()) (\($0.finishedTasks) of \($0.totalTasks))" } ?? "Starting scan…")
                .foregroundStyle(.secondary)
                .accessibilityAddTraits(.updatesFrequently)
            Button("Stop") { viewModel.stopScan() }
        }
        .padding(32)
    }

    @ViewBuilder
    private var results: some View {
        if viewModel.groups.isEmpty {
            VStack(spacing: 12) {
                Image(systemName: "checkmark.seal")
                    .font(.system(size: 48))
                    .foregroundStyle(.green)
                    .accessibilityHidden(true)
                Text("Your Mac is clean")
                    .font(.title2.weight(.semibold))
                Text("Nothing to remove right now. Check again after you use your apps for a while.")
                    .foregroundStyle(.secondary)
                Button("Scan Again") { viewModel.scan() }
            }
            .padding(32)
        } else {
            VStack(spacing: 0) {
                resultsHeader
                Divider()
                List {
                    ForEach(viewModel.groups) { group in
                        GroupRow(group: group, viewModel: viewModel)
                    }
                    if !viewModel.failures.isEmpty {
                        Section("Some checks did not finish") {
                            ForEach(viewModel.failures.sorted(by: { $0.key < $1.key }), id: \.key) { task, error in
                                Label("\(task): \(error)", systemImage: "exclamationmark.triangle")
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .listStyle(.inset)
            }
        }
    }

    private var resultsHeader: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(viewModel.totalSize.formattedBytes) found")
                    .font(.title2.weight(.semibold))
                Text("\(viewModel.selectedSize.formattedBytes) selected in \(viewModel.selectedItems.count) items")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Scan Again") { viewModel.scan() }
            Button("Clean") { viewModel.requestClean() }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(viewModel.selectedItems.isEmpty)
                .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
    }

    private func cleaning(done: Int, total: Int, current: String) -> some View {
        VStack(spacing: 16) {
            ProgressView(value: Double(done), total: Double(max(total, 1)))
                .frame(maxWidth: 360)
            Text(current.isEmpty ? "Cleaning…" : "Removing \(current)")
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 360)
            Button("Stop") { viewModel.stopCleaning() }
        }
        .padding(32)
    }

    private func cleaned(_ report: JunkCleanReport) -> some View {
        VStack(spacing: 16) {
            Image(systemName: report.outcome == .success ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .font(.system(size: 56))
                .foregroundStyle(report.outcome == .success ? Color.green : Color.orange)
                .accessibilityHidden(true)
            Text(report.outcome == .success ? "Cleanup complete" : "Some items were not removed")
                .font(.title.weight(.semibold))
            Text("\(report.removedSize.formattedBytes) freed")
                .foregroundStyle(.secondary)
            if !report.failures.isEmpty {
                Text("Quit the related apps and try again. Items that need administrator rights are not offered.")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 440)
                List(report.failures) { failure in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(failure.item.name)
                        Text(failure.error ?? "")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: 520, maxHeight: 200)
            }
            HStack {
                if !viewModel.groups.isEmpty {
                    Button("Review Remaining") { viewModel.reviewRemaining() }
                }
                Button("Scan Again") { viewModel.scan() }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(32)
    }
}

// MARK: Rows

/// Tri-state checkbox shared by the junk and applications screens.
struct CheckBox: View {
    let state: CheckState
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.title3)
                .foregroundStyle(state == .off ? Color.secondary : Color.accentColor)
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityValue(state == .on ? "selected" : state == .mixed ? "partly selected" : "not selected")
    }

    private var symbol: String {
        switch state {
        case .on: "checkmark.square.fill"
        case .off: "square"
        case .mixed: "minus.square.fill"
        }
    }
}

private struct SizeText: View {
    let bytes: Int64
    var body: some View {
        Text(bytes.formattedBytes)
            .monospacedDigit()
            .foregroundStyle(.secondary)
    }
}

private struct GroupRow: View {
    let group: JunkGroup
    @ObservedObject var viewModel: SystemJunkViewModel
    @State private var expanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            ForEach(group.subgroups) { subgroup in
                SubgroupRow(subgroup: subgroup, viewModel: viewModel)
            }
        } label: {
            HStack(spacing: 10) {
                CheckBox(state: viewModel.state(of: group.items), label: "Select \(group.id.title)") { viewModel.toggle(group.items) }
                Image(systemName: group.id.symbol)
                    .frame(width: 20)
                    .foregroundStyle(Color.accentColor)
                    .accessibilityHidden(true)
                Text(group.id.title)
                    .font(.headline)
                Spacer()
                SizeText(bytes: group.size)
            }
            .padding(.vertical, 4)
        }
    }
}

private struct SubgroupRow: View {
    let subgroup: JunkSubgroup
    @ObservedObject var viewModel: SystemJunkViewModel
    @State private var expanded = false

    var body: some View {
        if subgroup.items.count == 1, let item = subgroup.items.first, item.name == subgroup.title {
            ItemRow(item: item, viewModel: viewModel)
        } else {
            DisclosureGroup(isExpanded: $expanded) {
                ForEach(subgroup.items) { item in
                    ItemRow(item: item, viewModel: viewModel)
                }
            } label: {
                HStack(spacing: 10) {
                    CheckBox(state: viewModel.state(of: subgroup.items), label: "Select \(subgroup.title)") { viewModel.toggle(subgroup.items) }
                    Text(subgroup.title)
                    Text("\(subgroup.items.count)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    SizeText(bytes: subgroup.size)
                }
                .contextMenu {
                    if let owner = subgroup.bundleIdentifier {
                        Button("Ignore \(subgroup.title) in Future Scans") {
                            viewModel.ignore(path: owner, removing: Set(subgroup.items.map(\.id)))
                        }
                    }
                }
            }
        }
    }
}

private struct ItemRow: View {
    let item: JunkItem
    @ObservedObject var viewModel: SystemJunkViewModel

    var body: some View {
        HStack(spacing: 10) {
            CheckBox(state: viewModel.selection.contains(item.id) ? .on : .off, label: "Select \(item.name)") { viewModel.toggle([item]) }
            VStack(alignment: .leading, spacing: 1) {
                Text(item.name)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let detail = item.detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer()
            SizeText(bytes: item.size)
        }
        .help(item.url?.path ?? item.name)
        .contextMenu {
            if let url = item.url {
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                Button("Ignore in Future Scans") { viewModel.ignore(path: url.path, removing: [item.id]) }
            }
        }
    }
}
