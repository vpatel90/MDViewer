import SwiftUI

struct TOCSidebarView: View {
    let headings: [HeadingItem]
    let activeHeadingID: String?
    let onHeadingTap: (String) -> Void

    var body: some View {
        List {
            ForEach(headings) { heading in
                Button(action: { onHeadingTap(heading.id) }) {
                    Text(heading.text)
                        .font(.system(size: fontSize(for: heading.level),
                                      weight: heading.level <= 2 ? .semibold : .regular))
                        .foregroundStyle(heading.id == activeHeadingID ? .primary : .secondary)
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
                .padding(.leading, indentation(for: heading.level))
                .padding(.vertical, 2)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(heading.id == activeHeadingID ? Color.accentColor.opacity(0.1) : Color.clear)
                        .padding(.horizontal, -4)
                )
            }
        }
        .listStyle(.sidebar)
    }

    private func fontSize(for level: Int) -> CGFloat {
        switch level {
        case 1: return 13
        case 2: return 12.5
        default: return 12
        }
    }

    private func indentation(for level: Int) -> CGFloat {
        return CGFloat(max(0, level - 1)) * 12
    }
}
