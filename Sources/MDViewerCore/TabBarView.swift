import SwiftUI

struct TabBarView: View {
    @EnvironmentObject var manager: DocumentManager

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 0) {
                ForEach(manager.tabs) { tab in
                    TabItemView(
                        tab: tab,
                        isSelected: tab.id == manager.selectedTabID
                    )
                }
            }
            .padding(.leading, 1)
        }
    }
}

struct TabItemView: View {
    let tab: DocumentTab
    let isSelected: Bool
    @EnvironmentObject var manager: DocumentManager
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "doc.text")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)

            Text(tab.filename)
                .font(.system(size: 12, weight: isSelected ? .medium : .regular))
                .lineLimit(1)
                .foregroundStyle(isSelected ? .primary : .secondary)

            Button(action: { manager.closeTab(id: tab.id) }) {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .frame(width: 16, height: 16)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .opacity(isHovering || isSelected ? 1 : 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(isSelected
                    ? Color(nsColor: .controlBackgroundColor)
                    : (isHovering ? Color(nsColor: .controlBackgroundColor).opacity(0.5) : Color.clear))
                .padding(.vertical, 3)
                .padding(.horizontal, 2)
        )
        .onTapGesture {
            manager.selectedTabID = tab.id
        }
        .onHover { hovering in
            isHovering = hovering
        }
    }
}
