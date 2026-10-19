import SwiftUI

struct ToolboxView: View {
    @StateObject private var viewModel = ToolboxSearchViewModel()
    @FocusState private var searchFocused: Bool
    @State private var path: [JunkFlow] = []

    private let columns = [GridItem(.adaptive(minimum: 220, maximum: 320), spacing: 16)]
    private let suggestions = ["cache", "uninstall", "free space", "virus"]

    var body: some View {
        NavigationStack(path: $path) {
            VStack(spacing: 0) {
                header
                Divider()
                ScrollView {
                    content
                        .padding(24)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .background(Color(nsColor: .windowBackgroundColor))
            .navigationDestination(for: JunkFlow.self) { SystemJunkView(flow: $0) }
        }
        .frame(minWidth: 720, minHeight: 520)
        .onAppear { searchFocused = true }
    }

    private func open(_ tool: Tool) -> (() -> Void)? {
        tool.flow.map { flow in { path.append(flow) } }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Toolbox")
                .font(.largeTitle.weight(.semibold))
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                TextField("Search tools, e.g. cache, uninstall, free space", text: $viewModel.query)
                    .textFieldStyle(.plain)
                    .font(.title3)
                    .focused($searchFocused)
                    .onExitCommand { viewModel.query = "" }
                    .accessibilityLabel("Search tools")
                if !viewModel.query.isEmpty {
                    Button {
                        viewModel.query = ""
                        searchFocused = true
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                            .frame(width: 28, height: 28)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clear search")
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 10))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(searchFocused ? Color.accentColor : .clear, lineWidth: 2)
            )
        }
        .padding(24)
    }

    @ViewBuilder
    private var content: some View {
        switch viewModel.state {
        case .browsing:
            VStack(alignment: .leading, spacing: 28) {
                if !viewModel.favorites.isEmpty {
                    section("Favorites", tools: viewModel.favorites)
                }
                section("All Tools", tools: viewModel.others)
            }
        case .pending:
            ProgressView()
                .controlSize(.small)
                .frame(maxWidth: .infinity, minHeight: 120)
                .accessibilityLabel("Searching")
        case .results(let results) where results.isEmpty:
            emptyState
        case .results(let results):
            VStack(alignment: .leading, spacing: 12) {
                Text(results.count == 1 ? "1 tool found" : "\(results.count) tools found")
                    .font(.headline)
                    .foregroundStyle(.secondary)
                    .accessibilityAddTraits(.updatesFrequently)
                LazyVGrid(columns: columns, alignment: .leading, spacing: 16) {
                    ForEach(results) { result in
                        ToolCard(
                            tool: result.tool,
                            isFavorite: viewModel.favoriteIDs.contains(result.id),
                            matchedTags: result.matchedTags,
                            onToggleFavorite: { viewModel.toggleFavorite(result.tool) },
                            onOpen: open(result.tool)
                        )
                    }
                }
            }
        }
    }

    private func section(_ title: String, tools: [Tool]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.headline)
                .foregroundStyle(.secondary)
                .accessibilityAddTraits(.isHeader)
            LazyVGrid(columns: columns, alignment: .leading, spacing: 16) {
                ForEach(tools) { tool in
                    ToolCard(
                        tool: tool,
                        isFavorite: viewModel.favoriteIDs.contains(tool.id),
                        matchedTags: [],
                        onToggleFavorite: { viewModel.toggleFavorite(tool) },
                        onOpen: open(tool)
                    )
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 36))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text("No tools match “\(viewModel.query)”")
                .font(.title3.weight(.semibold))
            Text("Try a broader word, or one of these:")
                .foregroundStyle(.secondary)
            HStack(spacing: 8) {
                ForEach(suggestions, id: \.self) { suggestion in
                    Button(suggestion) { viewModel.query = suggestion }
                        .buttonStyle(.bordered)
                        .controlSize(.large)
                }
            }
        }
        .frame(maxWidth: .infinity, minHeight: 240)
    }
}

private struct ToolCard: View {
    let tool: Tool
    let isFavorite: Bool
    let matchedTags: Set<String>
    let onToggleFavorite: () -> Void
    /// Nil for tools that are not built yet.
    let onOpen: (() -> Void)?

    @State private var isHovered = false

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: tool.symbol)
                .font(.title2)
                .foregroundStyle(onOpen == nil ? Color.secondary : Color.accentColor)
                .frame(width: 36, height: 36)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(tool.title)
                        .font(.headline)
                    if onOpen == nil {
                        Text("Soon")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.quaternary, in: Capsule())
                            .foregroundStyle(.secondary)
                    }
                }
                Text(tool.description)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if !matchedTags.isEmpty {
                    Text("Matched: " + matchedTags.sorted().map { $0.replacingOccurrences(of: "_", with: " ") }.joined(separator: ", "))
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            Spacer(minLength: 0)
            Button(action: onToggleFavorite) {
                Image(systemName: isFavorite ? "star.fill" : "star")
                    .foregroundStyle(isFavorite ? Color.yellow : Color.secondary)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isFavorite ? "Remove \(tool.title) from favorites" : "Add \(tool.title) to favorites")
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background, in: RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(isHovered && onOpen != nil ? Color.accentColor.opacity(0.6) : Color.secondary.opacity(0.2))
        )
        .contentShape(RoundedRectangle(cornerRadius: 12))
        .onTapGesture { onOpen?() }
        .onHover { hovering in
            isHovered = hovering
            if onOpen != nil { hovering ? NSCursor.pointingHand.push() : NSCursor.pop() }
        }
        .animation(.easeOut(duration: 0.15), value: isHovered)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(onOpen == nil ? [] : .isButton)
        .accessibilityAction { onOpen?() }
    }
}
