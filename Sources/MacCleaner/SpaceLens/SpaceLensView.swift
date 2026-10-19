import SpaceLens
import SwiftUI

struct SpaceLensView: View {
    @StateObject private var viewModel = SpaceLensViewModel()

    var body: some View {
        Group {
            switch viewModel.phase {
            case .intro: SpaceLensIntro(viewModel: viewModel)
            case .scanning(let progress): scanning(progress)
            case .results: SpaceLensResults(viewModel: viewModel)
            case .removing(let done, let total): removing(done: done, total: total)
            case .finished(let removed, let failures): finished(removed: removed, failures: failures)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle("Space Lens")
        .sheet(isPresented: $viewModel.reviewing) { SpaceLensReview(viewModel: viewModel) }
    }

    private func scanning(_ progress: SpaceLensProgress?) -> some View {
        VStack(spacing: 14) {
            if let fraction = progress?.fraction {
                ProgressView(value: fraction).frame(maxWidth: 380)
            } else {
                ProgressView().controlSize(.large)
            }
            Text(progress.map { p in
                p.expectedBytes.map { "Scanned \(p.scannedBytes.formattedBytes) of \($0.formattedBytes)" } ?? "Scanned \(p.scannedBytes.formattedBytes)"
            } ?? "Starting scan…")
            .font(.headline)
            .accessibilityAddTraits(.updatesFrequently)
            Text(progress?.currentPath ?? " ")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 480)
            Button("Stop") { viewModel.stopScan() }
        }
        .padding(32)
    }

    private func removing(done: Int, total: Int) -> some View {
        VStack(spacing: 12) {
            ProgressView(value: Double(done), total: Double(max(total, 1))).frame(maxWidth: 360)
            Text("Removing files…").foregroundStyle(.secondary)
        }
    }

    private func finished(removed: Int64, failures: [SpaceLensRemovalResult]) -> some View {
        VStack(spacing: 14) {
            Image(systemName: failures.isEmpty ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .font(.system(size: 56))
                .foregroundStyle(failures.isEmpty ? Color.green : Color.orange)
                .accessibilityHidden(true)
            Text(failures.isEmpty ? "Removal complete!" : "Some files were not removed")
                .font(.title.weight(.semibold))
            (Text(removed.formattedBytes).foregroundStyle(LensColors.stroke).bold() + Text(" moved to the Trash"))
                .font(.title3)
            if !failures.isEmpty {
                Text("Make sure none of your apps are using them and try again.").foregroundStyle(.secondary)
                List(failures, id: \.node.id) { failure in
                    VStack(alignment: .leading) {
                        Text(failure.node.displayName)
                        Text(failure.error ?? "").font(.caption).foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: 520, maxHeight: 200)
            }
            HStack {
                Button("Review More Items") { viewModel.backToResults() }
                Button("Done") { viewModel.startOver() }.buttonStyle(.borderedProminent)
            }
        }
        .padding(32)
    }
}

// MARK: Intro

private struct SpaceLensIntro: View {
    @ObservedObject var viewModel: SpaceLensViewModel

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "circle.hexagongrid.fill")
                .font(.system(size: 56))
                .foregroundStyle(LensColors.stroke)
                .accessibilityHidden(true)
            Text("Space Lens").font(.largeTitle.weight(.bold))
            Text("See what takes up space: every folder becomes a bubble sized by how much it holds.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 440)
            HStack(spacing: 10) {
                Picker("Scan", selection: $viewModel.target) {
                    ForEach(viewModel.targets) { target in
                        Label(target.name, systemImage: target.symbol).tag(target)
                    }
                }
                .labelsHidden()
                .frame(width: 220)
                Button("Choose Folder…") { viewModel.chooseFolder() }
            }
            Button("Scan") { viewModel.scan() }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
            if !viewModel.hasFullDiskAccess {
                HStack(spacing: 6) {
                    Image(systemName: "lock.shield").foregroundStyle(.orange).accessibilityHidden(true)
                    Text("Without Full Disk Access, private folders such as Documents, Desktop, Mail and app data are shown but not measured.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Button("Open Settings") { viewModel.openFullDiskAccessSettings() }
                        .buttonStyle(.link)
                }
                .frame(maxWidth: 560)
            }
        }
        .padding(32)
    }
}

// MARK: Results

struct SpaceLensResults: View {
    @ObservedObject var viewModel: SpaceLensViewModel

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 16) {
                SpaceLensSidePanel(viewModel: viewModel)
                    .frame(width: 384)
                VStack(spacing: 8) {
                    LensPathBar(viewModel: viewModel)
                    if viewModel.level.main.isEmpty && viewModel.level.smaller.isEmpty {
                        VStack(spacing: 8) {
                            Text("Too empty to visualize…").font(.title3.weight(.semibold))
                            Text("This folder has nothing to show.").foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        BubbleCanvas(viewModel: viewModel)
                    }
                }
            }
            .padding(16)
            Divider()
            footer
        }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            if viewModel.selectedCount == 0 {
                Text("Nothing selected").foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    Text(viewModel.selectedSize.formattedBytes).font(.title3.weight(.semibold)).monospacedDigit()
                    Text("\(viewModel.selectedCount) \(viewModel.selectedCount == 1 ? "item" : "items") selected")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button("Start Over") { viewModel.startOver() }
            Button("Review and Remove") { viewModel.reviewing = true }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(viewModel.selectedCount == 0)
        }
        .padding(.horizontal, 20)
        .frame(height: 64)
    }
}

private struct LensPathBar: View {
    @ObservedObject var viewModel: SpaceLensViewModel

    var body: some View {
        HStack(spacing: 6) {
            Button { viewModel.goBack() } label: { Image(systemName: "chevron.left").frame(width: 24, height: 24) }
                .buttonStyle(.borderless)
                .disabled(!viewModel.canGoBack)
                .accessibilityLabel("Back")
            Button { viewModel.goForward() } label: { Image(systemName: "chevron.right").frame(width: 24, height: 24) }
                .buttonStyle(.borderless)
                .disabled(!viewModel.canGoForward)
                .accessibilityLabel("Forward")
            Divider().frame(height: 16)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    let lineage = viewModel.current?.lineage ?? []
                    ForEach(Array(lineage.enumerated()), id: \.element.id) { index, node in
                        if index > 0 {
                            Image(systemName: "chevron.compact.right").foregroundStyle(.tertiary).accessibilityHidden(true)
                        }
                        Button(node.displayName) { viewModel.open(node) }
                            .buttonStyle(.borderless)
                            .foregroundStyle(index == lineage.count - 1 ? Color.primary : Color.secondary)
                            .fontWeight(index == lineage.count - 1 ? .semibold : .regular)
                    }
                }
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 36)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
    }
}

private struct SpaceLensSidePanel: View {
    @ObservedObject var viewModel: SpaceLensViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let usage = viewModel.diskUsage { DiskUsageBar(usage: usage, selected: viewModel.selectedSize) }
            if let current = viewModel.current {
                HStack(spacing: 10) {
                    Image(nsImage: LensIcons.icon(for: current)).resizable().frame(width: 36, height: 36).accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(current.displayName).font(.headline).lineLimit(1).truncationMode(.middle)
                        Text("\(current.size.formattedBytes) · \(current.children.count) items")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Menu("Select") {
                        Button("Select All") { viewModel.selectAll() }
                        Button("Deselect All") { viewModel.deselectAll() }
                    }
                    .fixedSize()
                }
            }
            let level = viewModel.level
            List {
                ForEach(level.main) { node in LensRow(node: node, viewModel: viewModel) }
                if !level.smaller.isEmpty {
                    DisclosureGroup(isExpanded: $viewModel.smallerExpanded) {
                        ForEach(level.smaller) { node in LensRow(node: node, viewModel: viewModel) }
                    } label: {
                        HStack(spacing: 8) {
                            CheckBox(state: viewModel.state(of: level.smaller), label: "Select smaller items") { viewModel.toggle(level.smaller) }
                            Text("Smaller items (\(level.smaller.count))")
                            Spacer()
                            Text(level.smallerSize.formattedBytes).monospacedDigit().foregroundStyle(.secondary)
                        }
                    }
                }
                if !level.other.isEmpty {
                    Section("Other items") {
                        ForEach(level.other) { node in LensRow(node: node, viewModel: viewModel) }
                    }
                }
            }
            .listStyle(.inset)
            .clipShape(RoundedRectangle(cornerRadius: 10))
        }
    }
}

private struct LensRow: View {
    let node: SpaceLensNode
    @ObservedObject var viewModel: SpaceLensViewModel

    var body: some View {
        HStack(spacing: 8) {
            CheckBox(state: viewModel.state(of: node), label: "Select \(node.displayName)") { viewModel.toggle(node) }
                .disabled(!node.isSelectable)
                .opacity(node.isSelectable ? 1 : 0.35)
            Image(nsImage: LensIcons.icon(for: node)).resizable().frame(width: 22, height: 22).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(node.displayName).lineLimit(1).truncationMode(.middle)
                if let note { Text(note).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
            }
            Spacer()
            if node.cloud != .notCloud {
                Image(systemName: node.cloud == .evicted ? "icloud" : "icloud.fill")
                    .foregroundStyle(.secondary)
                    .help(node.cloud == .evicted ? "Cloud-only: not stored on this Mac" : "Also stored in the cloud")
            }
            Text(node.kind == .needsAccess ? "—" : node.size.formattedBytes).monospacedDigit().foregroundStyle(.secondary)
        }
        .frame(minHeight: 32)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { viewModel.open(node) }
        .contextMenu {
            if node.isSelectable { Button(viewModel.state(of: node) == .on ? "Deselect" : "Select") { viewModel.toggle(node) } }
            if node.isDirectory { Button("Open") { viewModel.open(node) } }
            if node.kind != .purgeable { Button("Reveal in Finder") { viewModel.reveal(node) } }
        }
    }

    private var note: String? {
        switch node.kind {
        case .needsAccess: "Needs Full Disk Access"
        case .purgeable: "Freed by macOS when space is needed"
        default: node.isProtected ? "Essential system item" : nil
        }
    }
}

private struct DiskUsageBar: View {
    let usage: SpaceLensViewModel.DiskUsage
    let selected: Int64

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("\(usage.used.formattedBytes) of \(usage.total.formattedBytes) used").font(.caption).foregroundStyle(.secondary)
            GeometryReader { proxy in
                let total = max(Double(usage.total), 1)
                let used = Double(usage.used) / total
                let purgeable = Double(usage.purgeable) / total
                let selectedShare = min(Double(selected) / total, used)
                ZStack(alignment: .leading) {
                    Capsule().fill(.quaternary)
                    Capsule().fill(LensColors.stroke).frame(width: proxy.size.width * used)
                    Capsule().fill(LensColors.purgeable).frame(width: proxy.size.width * purgeable).offset(x: proxy.size.width * max(used - purgeable, 0))
                    Capsule().fill(LensColors.selected).frame(width: proxy.size.width * selectedShare)
                }
            }
            .frame(height: 8)
            .help("Used \(usage.used.formattedBytes) · Free \((usage.total - usage.used).formattedBytes) · Purgeable \(usage.purgeable.formattedBytes) · Selected \(selected.formattedBytes)")
        }
    }
}

// MARK: Review

private struct SpaceLensReview: View {
    @ObservedObject var viewModel: SpaceLensViewModel

    var body: some View {
        let items = viewModel.plannedRemoval
        VStack(alignment: .leading, spacing: 14) {
            Text("Review Items Before Removal").font(.title2.weight(.semibold))
            Text("\(items.count) \(items.count == 1 ? "item" : "items"), \(viewModel.selectedSize.formattedBytes). Everything moves to the Trash, so you can put it back from there.")
                .foregroundStyle(.secondary)
            if viewModel.selectionTouchesCloud {
                Label("Some selected files are stored in iCloud or another cloud service; removing them removes them from the cloud too.", systemImage: "icloud.and.arrow.up")
                    .foregroundStyle(.orange)
            }
            List(items) { node in
                HStack(spacing: 8) {
                    Image(nsImage: LensIcons.icon(for: node)).resizable().frame(width: 22, height: 22).accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(node.displayName).lineLimit(1)
                        Text(node.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    }
                    Spacer()
                    Text(node.size.formattedBytes).monospacedDigit().foregroundStyle(.secondary)
                }
            }
            .frame(minHeight: 240)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { viewModel.reviewing = false }.keyboardShortcut(.cancelAction)
                Button("Move to Trash") { viewModel.remove() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 620, height: 520)
    }
}
