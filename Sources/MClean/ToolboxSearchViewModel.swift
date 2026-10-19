import Combine
import Foundation
import LookupService

@MainActor
final class ToolboxSearchViewModel: ObservableObject {
    enum State: Equatable {
        case browsing
        case pending
        case results([ToolResult])
    }

    struct ToolResult: Identifiable, Equatable {
        var tool: Tool
        var score: Double
        var matchedTags: Set<String>
        var id: String { tool.id }
    }

    @Published var query = ""
    @Published private(set) var state: State = .browsing
    @Published private(set) var favoriteIDs: Set<String> = ["system-junk", "space-lens"]

    let tools: [Tool]
    private let toolsByID: [String: Tool]
    private let lookupClient = LookupClient<String>()
    private let lookupBootstrapTask: Task<Void, Never>
    private var searchTask: Task<Void, Never>?
    private var cancellables = Set<AnyCancellable>()

    init(tools: [Tool] = ToolCatalog.all) {
        self.tools = tools
        toolsByID = Dictionary(uniqueKeysWithValues: tools.map { ($0.id, $0) })
        let documents = tools.map(\.lookupDocument)
        let client = lookupClient
        lookupBootstrapTask = Task { await client.index(documents) }

        $query
            .removeDuplicates()
            .debounce(for: .milliseconds(150), scheduler: DispatchQueue.main)
            .sink { [weak self] in self?.runSearch($0) }
            .store(in: &cancellables)
    }

    var favorites: [Tool] { tools.filter { favoriteIDs.contains($0.id) } }
    var others: [Tool] { tools.filter { !favoriteIDs.contains($0.id) } }

    func toggleFavorite(_ tool: Tool) {
        if favoriteIDs.remove(tool.id) == nil { favoriteIDs.insert(tool.id) }
    }

    private func runSearch(_ query: String) {
        searchTask?.cancel()
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            state = .browsing
            return
        }
        state = .pending
        let client = lookupClient
        let bootstrap = lookupBootstrapTask
        searchTask = Task { [weak self] in
            await bootstrap.value
            let matches = await client.search(trimmed)
            guard !Task.isCancelled, let self else { return }
            self.state = .results(matches.compactMap { match in
                self.toolsByID[match.id].map { ToolResult(tool: $0, score: match.score, matchedTags: match.matchedTags) }
            })
        }
    }
}
