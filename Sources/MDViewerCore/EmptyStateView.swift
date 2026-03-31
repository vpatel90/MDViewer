import SwiftUI

struct EmptyStateView: View {
    @EnvironmentObject var manager: DocumentManager

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "doc.richtext")
                .font(.system(size: 56, weight: .thin))
                .foregroundStyle(.quaternary)

            VStack(spacing: 8) {
                Text("MDViewer")
                    .font(.title)
                    .fontWeight(.medium)
                    .foregroundStyle(.secondary)

                Text("Open a Markdown file to get started")
                    .font(.body)
                    .foregroundStyle(.tertiary)
            }

            Button(action: { manager.openFileDialog() }) {
                Label("Open File", systemImage: "folder")
                    .font(.body)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)

            Text("or drag and drop .md files here")
                .font(.caption)
                .foregroundStyle(.quaternary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .transition(.scale(scale: 0.95).combined(with: .opacity))
    }
}
