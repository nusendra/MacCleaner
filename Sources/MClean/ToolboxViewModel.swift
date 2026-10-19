import Foundation

@MainActor
final class ToolboxViewModel: ObservableObject {
    @Published private(set) var favoriteIDs: Set<String> = ["system-junk", "uninstaller"]

    let tools: [Tool]

    init(tools: [Tool] = ToolCatalog.all) {
        self.tools = tools
    }

    var favorites: [Tool] { tools.filter { favoriteIDs.contains($0.id) } }
    var others: [Tool] { tools.filter { !favoriteIDs.contains($0.id) } }

    func toggleFavorite(_ tool: Tool) {
        if favoriteIDs.remove(tool.id) == nil { favoriteIDs.insert(tool.id) }
    }
}
