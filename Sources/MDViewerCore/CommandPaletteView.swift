import SwiftUI

struct CommandPaletteItem: Identifiable {
    let id = UUID()
    let icon: String
    let title: String
    let shortcut: String?
    let action: () -> Void
}

struct CommandPaletteView: View {
    @Binding var isPresented: Bool
    let items: [CommandPaletteItem]
    @State private var query = ""
    @State private var selectedIndex = 0

    var filteredItems: [CommandPaletteItem] {
        if query.isEmpty { return items }
        let lower = query.lowercased()
        return items.filter { $0.title.lowercased().contains(lower) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Type a command...", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 15))
                    .onSubmit { executeSelected() }
            }
            .padding(12)

            Divider()

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(filteredItems.prefix(10).enumerated()), id: \.element.id) { index, item in
                            HStack {
                                Image(systemName: item.icon)
                                    .frame(width: 20)
                                    .foregroundStyle(.secondary)
                                Text(item.title)
                                    .lineLimit(1)
                                Spacer()
                                if let shortcut = item.shortcut {
                                    Text(shortcut)
                                        .font(.caption)
                                        .foregroundStyle(.tertiary)
                                }
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(index == selectedIndex ? Color.accentColor.opacity(0.15) : Color.clear)
                            .cornerRadius(4)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                item.action()
                                isPresented = false
                            }
                            .id(item.id)
                        }
                    }
                    .padding(.vertical, 4)
                }
                .frame(maxHeight: 300)
            }
        }
        .frame(width: 500)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .shadow(color: .black.opacity(0.2), radius: 20, y: 10)
        .onKeyPress(.upArrow) {
            selectedIndex = max(0, selectedIndex - 1)
            return .handled
        }
        .onKeyPress(.downArrow) {
            selectedIndex = min(filteredItems.prefix(10).count - 1, selectedIndex + 1)
            return .handled
        }
        .onKeyPress(.escape) {
            isPresented = false
            return .handled
        }
        .onChange(of: query) { _, _ in
            selectedIndex = 0
        }
    }

    private func executeSelected() {
        let items = Array(filteredItems.prefix(10))
        guard selectedIndex < items.count else { return }
        items[selectedIndex].action()
        isPresented = false
    }
}
