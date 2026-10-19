import Foundation

public enum JunkCategory: String, CaseIterable, Sendable {
    case systemJunk
    case trashBins

    public var title: String {
        switch self {
        case .systemJunk: "System Junk"
        case .trashBins: "Trash Bins"
        }
    }
}

/// One scanner group, shown as a top-level row in the results.
public enum JunkGroupID: String, CaseIterable, Sendable {
    case userCaches, systemCaches, userLogs, systemLogs
    case brokenPreferences, brokenStartupItems, documentVersions
    case mobileBackups, deletedUsers, applicationLanguages, universalBinaries
    case xcodeJunk, trashes

    public var title: String {
        switch self {
        case .userCaches: "User Cache Files"
        case .systemCaches: "System Cache Files"
        case .userLogs: "User Log Files"
        case .systemLogs: "System Log Files"
        case .brokenPreferences: "Broken Preferences"
        case .brokenStartupItems: "Broken Login Items"
        case .documentVersions: "Document Versions"
        case .mobileBackups: "iOS Device Backups"
        case .deletedUsers: "Deleted Users"
        case .applicationLanguages: "Language Files"
        case .universalBinaries: "Universal Binaries"
        case .xcodeJunk: "Xcode Junk"
        case .trashes: "Trash Bins"
        }
    }

    public var category: JunkCategory { self == .trashes ? .trashBins : .systemJunk }

    public var symbol: String {
        switch self {
        case .userCaches, .systemCaches: "archivebox"
        case .userLogs, .systemLogs: "doc.text"
        case .brokenPreferences: "gearshape.2"
        case .brokenStartupItems: "power"
        case .documentVersions: "clock.arrow.circlepath"
        case .mobileBackups: "iphone"
        case .deletedUsers: "person.crop.circle.badge.minus"
        case .applicationLanguages: "globe"
        case .universalBinaries: "cpu"
        case .xcodeJunk: "hammer"
        case .trashes: "trash"
        }
    }
}

/// How a selected item is removed.
public enum RemovalAction: Hashable, Sendable {
    /// Permanent delete.
    case delete(URL)
    /// `.log`/`.txt` files are emptied so apps holding them open keep a valid file; anything else is deleted.
    case truncateOrDelete(URL)
    /// `defaults delete` the domain, then delete the plist.
    case removePreference(URL)
    /// `launchctl bootout` the agent, then delete the plist.
    case removeLaunchAgent(URL)
    /// Remove one stored revision of a document, identified by its modification date.
    case removeFileVersion(document: URL, modificationDate: Date)
    /// Run `simctl` with these arguments (`delete <udid>`, `runtime delete <id>`).
    case simctl([String])
    /// Rewrite a fat Mach-O so it keeps only `keepArchitecture`.
    case thinBinary(URL, keepArchitecture: String)
}

public struct JunkItem: Identifiable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var detail: String?
    public var url: URL?
    public var size: Int64
    public var isAutoSelected: Bool
    public var action: RemovalAction
    /// Apps that must not be running while this item is cleaned.
    public var quitBeforeCleaning: Set<String>

    public init(
        id: String? = nil,
        name: String,
        detail: String? = nil,
        url: URL?,
        size: Int64,
        isAutoSelected: Bool,
        action: RemovalAction,
        quitBeforeCleaning: Set<String> = []
    ) {
        self.id = id ?? url?.path ?? name
        self.name = name
        self.detail = detail
        self.url = url
        self.size = size
        self.isAutoSelected = isAutoSelected
        self.action = action
        self.quitBeforeCleaning = quitBeforeCleaning
    }
}

/// A second-level row: an app, a log source, an Xcode sub-category...
public struct JunkSubgroup: Identifiable, Hashable, Sendable {
    public var id: String
    public var title: String
    public var bundleIdentifier: String?
    public var items: [JunkItem]

    public init(id: String, title: String, bundleIdentifier: String? = nil, items: [JunkItem]) {
        self.id = id
        self.title = title
        self.bundleIdentifier = bundleIdentifier
        self.items = items
    }

    public var size: Int64 { items.reduce(0) { $0 + $1.size } }
}

public struct JunkGroup: Identifiable, Hashable, Sendable {
    public var id: JunkGroupID
    public var subgroups: [JunkSubgroup]

    public init(id: JunkGroupID, subgroups: [JunkSubgroup]) {
        self.id = id
        self.subgroups = subgroups
    }

    public var size: Int64 { subgroups.reduce(0) { $0 + $1.size } }
    public var items: [JunkItem] { subgroups.flatMap(\.items) }
}

public struct JunkScanResult: Sendable {
    public var groups: [JunkGroup]
    public var failures: [String: String]

    public var allItems: [JunkItem] { groups.flatMap(\.items) }
    public var totalSize: Int64 { groups.reduce(0) { $0 + $1.size } }
}
