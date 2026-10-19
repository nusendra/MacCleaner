/// Text a tool exposes to search, split by how much each field should count.
struct ToolSearchPayload: Hashable, Sendable {
    var title: String
    var description: String
    var moduleName: String
    var sharedKeywords: [String] = []
    var flowKeywords: [String] = []
    var searchKeywords: [String] = []
}

struct Tool: Identifiable, Hashable, Sendable {
    var id: String
    var symbol: String
    var search: ToolSearchPayload

    var title: String { search.title }
    var description: String { search.description }

    /// The screen this tool opens, if it is implemented.
    var destination: ToolDestination? {
        switch id {
        case "system-junk": .junk(.systemJunk)
        case "trash-bins": .junk(.trashBins)
        case "uninstaller": .applications(.applications)
        case "leftovers": .applications(.leftovers)
        case "space-lens": .spaceLens
        default: nil
        }
    }
}

enum ToolDestination: Hashable {
    case junk(JunkFlow)
    case applications(AppsSection)
    case spaceLens
}

enum ToolCatalog {
    static let all: [Tool] = [
        Tool(id: "system-junk", symbol: "trash", search: .init(
            title: "System Junk",
            description: "Remove caches, logs and temporary files left behind by macOS and apps.",
            moduleName: "Cleanup",
            sharedKeywords: ["clean", "free space"],
            flowKeywords: ["cache", "logs", "temp"],
            searchKeywords: ["junk", "garbage", "disk"])),
        Tool(id: "trash-bins", symbol: "trash.slash", search: .init(
            title: "Trash Bins",
            description: "Empty every Trash, including those on external drives.",
            moduleName: "Cleanup",
            sharedKeywords: ["clean", "free space"],
            flowKeywords: ["bin", "delete"],
            searchKeywords: ["trash", "recycle"])),
        Tool(id: "uninstaller", symbol: "xmark.app", search: .init(
            title: "Uninstaller",
            description: "Remove apps completely together with their support files.",
            moduleName: "Applications",
            sharedKeywords: ["apps"],
            flowKeywords: ["remove app", "delete app"],
            searchKeywords: ["uninstall", "remove"])),
        Tool(id: "leftovers", symbol: "shippingbox", search: .init(
            title: "Leftovers",
            description: "Find files that belonged to apps you already deleted.",
            moduleName: "Applications",
            sharedKeywords: ["apps"],
            flowKeywords: ["orphan", "remnants"],
            searchKeywords: ["leftover", "residue"])),
        Tool(id: "space-lens", symbol: "circle.hexagongrid", search: .init(
            title: "Space Lens",
            description: "Visualize folders by size to see what takes up your disk.",
            moduleName: "Storage",
            sharedKeywords: ["free space"],
            flowKeywords: ["folder size", "disk map"],
            searchKeywords: ["storage", "large files"])),
        Tool(id: "large-old-files", symbol: "doc.badge.clock", search: .init(
            title: "Large & Old Files",
            description: "Review big files you have not opened in months.",
            moduleName: "Storage",
            sharedKeywords: ["free space"],
            flowKeywords: ["big files", "old files"],
            searchKeywords: ["large", "unused"])),
        Tool(id: "duplicates", symbol: "square.on.square", search: .init(
            title: "Duplicates",
            description: "Find identical files and similar photos.",
            moduleName: "Storage",
            sharedKeywords: ["free space"],
            flowKeywords: ["copies", "similar photos"],
            searchKeywords: ["duplicate", "dupes"])),
        Tool(id: "maintenance", symbol: "wrench.and.screwdriver", search: .init(
            title: "Maintenance",
            description: "Run scripts, free RAM and reindex Spotlight.",
            moduleName: "Performance",
            sharedKeywords: ["speed"],
            flowKeywords: ["free ram", "reindex spotlight", "flush dns"],
            searchKeywords: ["optimize", "tune up"])),
    ]
}
