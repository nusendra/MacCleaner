import Foundation

/// The groups shown in an app's detail view, in display order.
public enum ResourceGroup: String, CaseIterable, Sendable {
    case binaries = "Binaries"
    case preferences = "Preferences"
    case supportingFiles = "Supporting Files"
    case caches = "Caches"
    case containers = "Containers"
    case userData = "User Data"
    case logs = "Logs"
    case loginItems = "Login Items"
    case plugins = "Plugins"
    case dockIcon = "Dock Icon"
    case installers = "Installers"
    case other = "Other"

    public var symbol: String {
        switch self {
        case .binaries: "app"
        case .preferences: "gearshape"
        case .supportingFiles: "folder"
        case .caches: "archivebox"
        case .containers: "shippingbox"
        case .userData: "person.crop.square"
        case .logs: "doc.text"
        case .loginItems: "power"
        case .plugins: "puzzlepiece.extension"
        case .dockIcon: "dock.rectangle"
        case .installers: "opticaldiscdrive"
        case .other: "doc"
        }
    }
}

public enum ResourceRemoval: Hashable, Sendable {
    /// Move the file or folder to the Trash.
    case trash(URL)
    /// `defaults delete` the domain (so cfprefsd drops its cached copy), then trash the plist.
    case preferences(URL)
    /// `launchctl bootout` the job, then trash its plist.
    case launchAgent(URL, label: String?)
    /// A helper inside the app registered as a login item: `launchctl bootout gui/<uid>/<label>`. The file goes with the bundle.
    case loginItemHelper(label: String)
    /// Remove the app's tile from the Dock.
    case dockTile(appPath: String)
}

public struct AppResource: Identifiable, Hashable, Sendable {
    public var id: String { "\(group.rawValue):\(path)" }
    public var path: String
    public var group: ResourceGroup
    public var size: Int64
    /// False for things we must not touch (App Store / system bundles, items we lack permission for).
    public var isRemovable: Bool
    public var removal: ResourceRemoval
    public var note: String?

    public init(path: String, group: ResourceGroup, size: Int64, isRemovable: Bool = true, removal: ResourceRemoval, note: String? = nil) {
        self.path = path
        self.group = group
        self.size = size
        self.isRemovable = isRemovable
        self.removal = removal
        self.note = note
    }

    public var url: URL { URL(fileURLWithPath: path) }
    public var displayName: String {
        switch removal {
        case .dockTile: "Dock icon"
        case .loginItemHelper(let label): label
        default: (path as NSString).lastPathComponent
        }
    }
}
