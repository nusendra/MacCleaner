import AppKit
import Duplicates
import Foundation
import JunkCleanup

enum DuplicatesTab: String, CaseIterable, Identifiable {
    case duplicates = "Duplicates"
    case similar = "Similar Photos"
    var id: String { rawValue }
}

/// A file shown in a group, from either feature.
struct GroupMember: Identifiable, Hashable {
    var url: URL
    var size: Int64
    var modified: Date?
    var badge: String?
    var id: String { url.path }
}

/// A group in the list, from either feature.
struct MemberGroup: Identifiable, Hashable {
    var id: String
    var title: String
    var subtitle: String
    var members: [GroupMember]
    /// Paths Smart Select / Best Quality picks for removal.
    var suggested: Set<String>
    var kind: DuplicateKind?
    var size: Int64 { members.reduce(0) { $0 + $1.size } }
}

enum GroupSelectOption: String, CaseIterable, Identifiable {
    case smart = "Smartly", bestQuality = "Best Quality", oldest = "Oldest", newest = "Newest"
    case smallest = "Smallest", largest = "Largest", none = "Deselect All"
    var id: String { rawValue }

    static let forDuplicates: [GroupSelectOption] = [.smart, .oldest, .newest, .none]
    static let forSimilar: [GroupSelectOption] = [.bestQuality, .oldest, .newest, .smallest, .largest, .none]
}

@MainActor
final class DuplicatesViewModel: ObservableObject {
    enum Phase {
        case intro
        case scanning(DuplicatesScanPhase?)
        case results
        case removing
        case finished(removed: Int64, failures: [String: String])
    }

    @Published var folder: URL = JunkPaths.current.home
    @Published private(set) var phase: Phase = .intro
    @Published var tab: DuplicatesTab = .duplicates
    @Published var kindFilter: DuplicateKind?
    @Published private(set) var duplicateGroups: [MemberGroup] = []
    @Published private(set) var similarGroups: [MemberGroup] = []
    @Published var focusedGroupID: String?
    /// Selected file paths (for removal).
    @Published var selection: Set<String> = []
    @Published var confirmingRemoval = false
    @Published var confirmingSelectAll: MemberGroup?
    var hasFullDiskAccess: Bool { Permissions.hasFullDiskAccess }

    private var scanner: DuplicatesScanner?

    var folderName: String { folder.path == JunkPaths.current.home.path ? "Home" : FileManager.default.displayName(atPath: folder.path) }

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Choose"
        if panel.runModal() == .OK, let url = panel.url { folder = url }
    }

    func scan() {
        let scanner = DuplicatesScanner(hasFullDiskAccess: hasFullDiskAccess)
        self.scanner = scanner
        phase = .scanning(nil)
        let folder = folder
        Task {
            do {
                let result = try await scanner.scan(folder) { progress in
                    Task { @MainActor [weak self] in
                        guard let self, case .scanning = self.phase else { return }
                        self.phase = .scanning(progress)
                    }
                }
                duplicateGroups = result.duplicates.map(Self.group(from:))
                similarGroups = result.similarImages.map(Self.group(from:))
                // Duplicates come preselected by Smart Select; similar photos start unselected, as in CleanMyMac.
                selection = Set(duplicateGroups.flatMap(\.suggested))
                tab = duplicateGroups.isEmpty && !similarGroups.isEmpty ? .similar : .duplicates
                focusedGroupID = visibleGroups.first?.id
                phase = .results
            } catch {
                phase = .intro
            }
        }
    }

    func stop() {
        scanner?.cancel()
        phase = .intro
    }

    private static func group(from group: DuplicateGroup) -> MemberGroup {
        let members = group.files.enumerated().map { index, file in
            GroupMember(url: file.url, size: file.size, modified: file.modified, badge: index == group.keptIndex ? "Keep" : nil)
        }
        let suggested = Set(group.autoselected.map { group.files[$0].path })
        return MemberGroup(id: "dup:" + group.id, title: group.title, subtitle: "\(group.files.count) copies · \(group.size.formattedBytes) each",
                           members: members, suggested: suggested, kind: group.kind)
    }

    private static func group(from group: SimilarImageGroup) -> MemberGroup {
        let members = group.images.map { image in
            GroupMember(url: image.file.url, size: image.file.size, modified: image.file.modified,
                        badge: image.isBest ? "One of the best to keep" : image.isExactCopy ? "Exact copy" : nil)
        }
        let suggested = Set(group.images.filter { !$0.isBest }.map(\.file.path))
        let date = group.images.compactMap(\.file.modified).min()
        let title = date.map { $0.formatted(date: .abbreviated, time: .omitted) } ?? group.images[0].file.name
        return MemberGroup(id: "sim:" + group.id, title: title, subtitle: "\(group.images.count) similar photos",
                           members: members, suggested: suggested, kind: nil)
    }

    // MARK: Lists

    var visibleGroups: [MemberGroup] {
        switch tab {
        case .duplicates: duplicateGroups.filter { kindFilter == nil || $0.kind == kindFilter }
        case .similar: similarGroups
        }
    }

    var availableKinds: [DuplicateKind] {
        DuplicateKind.allCases.filter { kind in duplicateGroups.contains { $0.kind == kind } }
    }

    var focusedGroup: MemberGroup? { visibleGroups.first { $0.id == focusedGroupID } ?? visibleGroups.first }

    func selectedCount(in group: MemberGroup) -> Int { group.members.filter { selection.contains($0.id) }.count }

    func state(of group: MemberGroup) -> CheckState {
        let count = selectedCount(in: group)
        return count == 0 ? .off : count == group.members.count ? .on : .mixed
    }

    // MARK: Selection

    func toggle(_ member: GroupMember, in group: MemberGroup) {
        if selection.contains(member.id) {
            selection.remove(member.id)
        } else if selectedCount(in: group) == group.members.count - 1 {
            confirmingSelectAll = group // would remove every copy of the file
            pendingMember = member
        } else {
            selection.insert(member.id)
        }
    }

    private var pendingMember: GroupMember?

    func confirmSelectAll(_ group: MemberGroup) {
        if let member = pendingMember { selection.insert(member.id) } else { selection.formUnion(group.members.map(\.id)) }
        pendingMember = nil
        confirmingSelectAll = nil
    }

    func cancelSelectAll() {
        pendingMember = nil
        confirmingSelectAll = nil
    }

    /// Group checkbox: toggles the suggested files (never all copies at once).
    func toggleGroup(_ group: MemberGroup) {
        let ids = group.members.map(\.id)
        if state(of: group) != .off {
            selection.subtract(ids)
        } else {
            selection.formUnion(group.suggested.isEmpty ? Set(ids.dropFirst()) : group.suggested)
        }
    }

    func apply(_ option: GroupSelectOption, to group: MemberGroup) {
        let ids = group.members.map(\.id)
        selection.subtract(ids)
        let dated = group.members.filter { $0.modified != nil }
        switch option {
        case .smart, .bestQuality:
            selection.formUnion(group.suggested)
        case .oldest:
            // Keep the newest copy, select the older ones.
            if let newest = dated.max(by: { $0.modified! < $1.modified! }) { selection.formUnion(ids.filter { $0 != newest.id }) }
        case .newest:
            if let oldest = dated.min(by: { $0.modified! < $1.modified! }) { selection.formUnion(ids.filter { $0 != oldest.id }) }
        case .smallest:
            if let largest = group.members.max(by: { $0.size < $1.size }) { selection.formUnion(ids.filter { $0 != largest.id }) }
        case .largest:
            if let smallest = group.members.min(by: { $0.size < $1.size }) { selection.formUnion(ids.filter { $0 != smallest.id }) }
        case .none:
            break
        }
    }

    var selectedMembers: [GroupMember] {
        let all = duplicateGroups.flatMap(\.members) + similarGroups.flatMap(\.members)
        var seen = Set<String>()
        return all.filter { selection.contains($0.id) && seen.insert($0.id).inserted }
    }

    var selectedSize: Int64 { selectedMembers.reduce(0) { $0 + $1.size } }

    // MARK: Removal

    func remove() {
        let members = selectedMembers
        phase = .removing
        Task {
            let failures = await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    continuation.resume(returning: DuplicatesScanner.trash(members.map(\.url)))
                }
            }
            let removed = members.filter { failures[$0.id] == nil }
            let removedIDs = Set(removed.map(\.id))
            selection.subtract(removedIDs)
            func prune(_ groups: [MemberGroup]) -> [MemberGroup] {
                groups.compactMap { group in
                    var group = group
                    group.members.removeAll { removedIDs.contains($0.id) }
                    return group.members.count > 1 ? group : nil
                }
            }
            duplicateGroups = prune(duplicateGroups)
            similarGroups = prune(similarGroups)
            phase = .finished(removed: removed.reduce(0) { $0 + $1.size }, failures: failures)
        }
    }

    func backToResults() { phase = .results }
    func startOver() { phase = .intro }
    func reveal(_ member: GroupMember) { NSWorkspace.shared.activateFileViewerSelecting([member.url]) }
    func openFile(_ member: GroupMember) { NSWorkspace.shared.open(member.url) }
}
