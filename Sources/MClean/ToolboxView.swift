import SwiftUI

struct ToolboxView: View {
    @StateObject private var viewModel = ToolboxViewModel()
    @State private var path: [ToolDestination] = []

    private let columns = [GridItem(.adaptive(minimum: 220, maximum: 320), spacing: 16)]

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    Text("Toolbox")
                        .font(.largeTitle.weight(.semibold))
                    if !viewModel.favorites.isEmpty {
                        section("Favorites", tools: viewModel.favorites)
                    }
                    section("All Tools", tools: viewModel.others)
                }
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(Color(nsColor: .windowBackgroundColor))
            .navigationDestination(for: ToolDestination.self) { destination in
                switch destination {
                case .junk(let flow): SystemJunkView(flow: flow)
                case .applications(let section): ApplicationsView(section: section)
                }
            }
        }
        .frame(minWidth: 720, minHeight: 520)
    }

    private func open(_ tool: Tool) -> (() -> Void)? {
        tool.destination.map { destination in { path.append(destination) } }
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
                        onToggleFavorite: { viewModel.toggleFavorite(tool) },
                        onOpen: open(tool)
                    )
                }
            }
        }
    }
}

private struct ToolCard: View {
    let tool: Tool
    let isFavorite: Bool
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
            }
            Spacer(minLength: 0)
            Button(action: onToggleFavorite) {
                Image(systemName: isFavorite ? "star.fill" : "star")
                    .foregroundStyle(isFavorite ? Color.yellow : Color.secondary)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
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
