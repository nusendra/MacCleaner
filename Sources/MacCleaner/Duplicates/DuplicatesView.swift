import Duplicates
import QuickLookThumbnailing
import SwiftUI

struct DuplicatesView: View {
    @StateObject private var viewModel = DuplicatesViewModel()

    var body: some View {
        Group {
            switch viewModel.phase {
            case .intro: intro
            case .scanning(let phase): scanning(phase)
            case .results: DuplicatesResults(viewModel: viewModel)
            case .removing:
                VStack(spacing: 12) { ProgressView(); Text("Moving files to the Trash…").foregroundStyle(.secondary) }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .finished(let removed, let failures): finished(removed: removed, failures: failures)
            }
        }
        .navigationTitle("Duplicates")
    }

    private var intro: some View {
        VStack(spacing: 18) {
            Image(systemName: "square.on.square")
                .font(.system(size: 52, weight: .medium))
                .foregroundStyle(Color.accentColor)
                .accessibilityHidden(true)
            Text("Duplicates").font(.largeTitle.weight(.bold))
            Text("Find identical files and similar photos, then keep the best copy of each.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            HStack(spacing: 10) {
                Label(viewModel.folderName, systemImage: "folder")
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                Button("Choose Folder…") { viewModel.chooseFolder() }
            }
            Button("Scan") { viewModel.scan() }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
            if !viewModel.hasFullDiskAccess {
                Text("Desktop, Documents and Downloads are skipped without Full Disk Access. Choose one of them as the folder to scan it anyway.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 480)
            }
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func scanning(_ phase: DuplicatesScanPhase?) -> some View {
        VStack(spacing: 14) {
            switch phase {
            case .hashing(let done, let total), .comparingImages(let done, let total):
                ProgressView(value: Double(done), total: Double(max(total, 1))).frame(maxWidth: 380)
            default:
                ProgressView().controlSize(.large)
            }
            Text(label(for: phase)).font(.headline).accessibilityAddTraits(.updatesFrequently)
            Button("Stop") { viewModel.stop() }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func label(for phase: DuplicatesScanPhase?) -> String {
        switch phase {
        case .enumerating(let found): "Looking for files… \(found) found"
        case .hashing(let done, let total): "Comparing files… \(done) of \(total)"
        case .comparingImages(let done, let total): "Comparing photos… \(done) of \(total)"
        case nil: "Starting…"
        }
    }

    private func finished(removed: Int64, failures: [String: String]) -> some View {
        VStack(spacing: 14) {
            Image(systemName: failures.isEmpty ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .font(.system(size: 52))
                .foregroundStyle(failures.isEmpty ? Color.green : Color.orange)
                .accessibilityHidden(true)
            Text(failures.isEmpty ? "Done" : "Some files were not removed").font(.title.weight(.semibold))
            Text("\(removed.formattedBytes) moved to the Trash").foregroundStyle(.secondary)
            if !failures.isEmpty {
                List(failures.sorted(by: { $0.key < $1.key }), id: \.key) { path, error in
                    VStack(alignment: .leading) { Text((path as NSString).lastPathComponent); Text(error).font(.caption).foregroundStyle(.secondary) }
                }
                .frame(maxWidth: 520, maxHeight: 200)
            }
            HStack {
                Button("Review More") { viewModel.backToResults() }
                Button("Done") { viewModel.startOver() }.buttonStyle(.borderedProminent)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct DuplicatesResults: View {
    @ObservedObject var viewModel: DuplicatesViewModel

    var body: some View {
        VStack(spacing: 0) {
            HSplitView {
                groupList.frame(minWidth: 300, idealWidth: 340, maxWidth: 440)
                detail.frame(minWidth: 420, maxWidth: .infinity)
            }
            Divider()
            HStack {
                Text(viewModel.selectedMembers.isEmpty ? "Nothing selected"
                     : "\(viewModel.selectedSize.formattedBytes) selected in \(viewModel.selectedMembers.count) files")
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Start Over") { viewModel.startOver() }
                Button("Remove") { viewModel.confirmingRemoval = true }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(viewModel.selectedMembers.isEmpty)
            }
            .padding(.horizontal, 20)
            .frame(height: 64)
        }
        .confirmationDialog("Move \(viewModel.selectedMembers.count) files to the Trash?", isPresented: $viewModel.confirmingRemoval, titleVisibility: .visible) {
            Button("Move to Trash", role: .destructive) { viewModel.remove() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("\(viewModel.selectedSize.formattedBytes) will be moved to the Trash. You can put files back from there.")
        }
        .alert("Select every copy?", isPresented: Binding(get: { viewModel.confirmingSelectAll != nil }, set: { if !$0 { viewModel.cancelSelectAll() } })) {
            Button("Select All", role: .destructive) { if let group = viewModel.confirmingSelectAll { viewModel.confirmSelectAll(group) } }
            Button("Cancel", role: .cancel) { viewModel.cancelSelectAll() }
        } message: {
            Text("This removes all instances of the file, leaving no copy behind.")
        }
    }

    private var groupList: some View {
        VStack(spacing: 8) {
            Picker("Show", selection: $viewModel.tab) {
                ForEach(DuplicatesTab.allCases) { tab in
                    Text("\(tab.rawValue) (\(tab == .duplicates ? viewModel.duplicateGroups.count : viewModel.similarGroups.count))").tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding([.horizontal, .top], 12)
            if viewModel.tab == .duplicates, viewModel.availableKinds.count > 1 {
                Picker("Kind", selection: $viewModel.kindFilter) {
                    Text("All kinds").tag(DuplicateKind?.none)
                    ForEach(viewModel.availableKinds, id: \.self) { Text($0.rawValue).tag(DuplicateKind?.some($0)) }
                }
                .labelsHidden()
                .padding(.horizontal, 12)
            }
            if viewModel.visibleGroups.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "checkmark.seal").font(.largeTitle).foregroundStyle(.green).accessibilityHidden(true)
                    Text(viewModel.tab == .duplicates ? "No duplicates found" : "No similar photos found").foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(viewModel.visibleGroups, selection: $viewModel.focusedGroupID) { group in
                    HStack(spacing: 10) {
                        CheckBox(state: viewModel.state(of: group), label: "Select \(group.title)") { viewModel.toggleGroup(group) }
                        Thumbnail(url: group.members[0].url, size: 36)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(group.title).lineLimit(1).truncationMode(.middle)
                            Text(group.subtitle).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(group.size.formattedBytes).monospacedDigit().foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 2)
                    .tag(group.id)
                }
                .listStyle(.inset)
            }
        }
    }

    @ViewBuilder
    private var detail: some View {
        if let group = viewModel.focusedGroup {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(group.title).font(.title3.weight(.semibold)).lineLimit(1).truncationMode(.middle)
                        Text(group.subtitle).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Menu("Select") {
                        ForEach(viewModel.tab == .duplicates ? GroupSelectOption.forDuplicates : GroupSelectOption.forSimilar) { option in
                            Button(option.rawValue) { viewModel.apply(option, to: group) }
                        }
                    }
                    .fixedSize()
                }
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 200), spacing: 12)], spacing: 12) {
                        ForEach(group.members) { member in
                            MemberCard(member: member, isSelected: viewModel.selection.contains(member.id),
                                       toggle: { viewModel.toggle(member, in: group) },
                                       reveal: { viewModel.reveal(member) }, open: { viewModel.openFile(member) })
                        }
                    }
                }
            }
            .padding(20)
        } else {
            Text("Select a group").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

private struct MemberCard: View {
    let member: GroupMember
    let isSelected: Bool
    let toggle: () -> Void
    let reveal: () -> Void
    let open: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .topLeading) {
                Thumbnail(url: member.url, size: 176)
                    .frame(maxWidth: .infinity)
                    .frame(height: 140)
                    .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
                CheckBox(state: isSelected ? .on : .off, label: "Select \(member.url.lastPathComponent)", action: toggle)
                    .background(Circle().fill(.background).padding(4))
                    .padding(4)
            }
            if let badge = member.badge {
                Text(badge)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(badge == "Exact copy" ? Color.orange : Color.green)
            }
            Text(member.url.lastPathComponent).font(.callout.weight(.medium)).lineLimit(1).truncationMode(.middle)
            Text(member.url.deletingLastPathComponent().path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            HStack {
                Text(member.size.formattedBytes)
                Spacer()
                if let date = member.modified { Text(date.formatted(date: .abbreviated, time: .shortened)) }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(10)
        .background(.background, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(isSelected ? Color.accentColor : Color.secondary.opacity(0.18), lineWidth: isSelected ? 2 : 1))
        .contentShape(RoundedRectangle(cornerRadius: 12))
        .onTapGesture(perform: toggle)
        .help(member.url.path)
        .contextMenu {
            Button("Open") { open() }
            Button("Reveal in Finder") { reveal() }
        }
    }
}

/// Quick Look thumbnail, falling back to the Finder icon.
struct Thumbnail: View {
    let url: URL
    let size: CGFloat
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
            } else {
                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().aspectRatio(contentMode: .fit)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size > 60 ? 6 : 4))
        .accessibilityHidden(true)
        .task(id: url) {
            let request = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: size, height: size), scale: 2, representationTypes: .thumbnail)
            if let representation = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request) {
                image = representation.nsImage
            }
        }
    }
}
