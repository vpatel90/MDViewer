import SwiftUI

struct TabBarView: View {
    @EnvironmentObject var manager: DocumentManager
    @Namespace private var tabNamespace

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 0) {
                ForEach(manager.tabs) { tab in
                    TabItemView(
                        tab: tab,
                        isSelected: tab.id == manager.selectedTabID,
                        namespace: tabNamespace
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
    var namespace: Namespace.ID
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
            .animation(.easeInOut(duration: 0.15), value: isHovering)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(
            Group {
                if isSelected {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color(nsColor: .controlBackgroundColor))
                        .matchedGeometryEffect(id: "activeTab", in: namespace)
                } else if isHovering {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color(nsColor: .controlBackgroundColor).opacity(0.5))
                }
            }
            .padding(.vertical, 3)
            .padding(.horizontal, 2)
        )
        .animation(.spring(.snappy), value: isSelected)
        .onTapGesture {
            manager.selectedTabID = tab.id
        }
        .onHover { hovering in
            isHovering = hovering
        }
    }
}
