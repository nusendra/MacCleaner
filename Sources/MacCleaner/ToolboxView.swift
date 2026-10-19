import SwiftUI

struct ToolboxView: View {
    @StateObject private var viewModel = ToolboxViewModel()
    @State private var path: [ToolDestination] = []

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                ToolboxGrid(viewModel: viewModel, open: open)
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
}

/// The Toolbox page content, separate from navigation so it can also be rendered offscreen (`--snapshot`).
struct ToolboxGrid: View {
    @ObservedObject var viewModel: ToolboxViewModel
    let open: (Tool) -> (() -> Void)?

    /// Columns grow to fill the window; each is at least 260 pt so a description fits in two lines.
    private let columns = [GridItem(.adaptive(minimum: 260), spacing: 16, alignment: .top)]

    var body: some View {
        VStack(alignment: .leading, spacing: 32) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Toolbox")
                    .font(.largeTitle.weight(.bold))
                Text("Pick a tool to clean up and manage your Mac.")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
            if !viewModel.favorites.isEmpty {
                section("Favorites", tools: viewModel.favorites)
            }
            section("All Tools", tools: viewModel.others)
        }
        .padding(.horizontal, 32)
        .padding(.vertical, 28)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func section(_ title: String, tools: [Tool]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.title3.weight(.semibold))
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

    private var isAvailable: Bool { onOpen != nil }
    private var tint: Color { isAvailable ? .accentColor : .secondary }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                Image(systemName: tool.symbol)
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(tint)
                    .frame(width: 44, height: 44)
                    .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
                    .accessibilityHidden(true)
                Spacer()
                if !isAvailable {
                    Text("Soon")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(.quaternary, in: Capsule())
                }
                favoriteStar
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(tool.title)
                    .font(.headline)
                    .lineLimit(1)
                Text(tool.description)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(2, reservesSpace: true)
                    .help(tool.description)
                    .multilineTextAlignment(.leading)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(.background, in: RoundedRectangle(cornerRadius: 14))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(isHovered && isAvailable ? Color.accentColor.opacity(0.7) : Color.secondary.opacity(0.18), lineWidth: isHovered && isAvailable ? 1.5 : 1)
        )
        .shadow(color: .black.opacity(isHovered && isAvailable ? 0.08 : 0.03), radius: isHovered && isAvailable ? 8 : 3, y: 1)
        .opacity(isAvailable ? 1 : 0.75)
        .contentShape(RoundedRectangle(cornerRadius: 14))
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

    /// An image with a tap target instead of a Button: it sits inside the card's own tap area,
    /// and renders correctly in offscreen snapshots.
    private var favoriteStar: some View {
        Image(systemName: isFavorite ? "star.fill" : "star")
            .font(.system(size: 15))
            .foregroundStyle(isFavorite ? Color.yellow : Color.secondary.opacity(0.7))
            .frame(width: 30, height: 30)
            .contentShape(Rectangle())
            .onTapGesture(perform: onToggleFavorite)
            .help(isFavorite ? "Remove from Favorites" : "Add to Favorites")
            .accessibilityElement()
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel(isFavorite ? "Remove \(tool.title) from favorites" : "Add \(tool.title) to favorites")
            .accessibilityAction { onToggleFavorite() }
    }
}
