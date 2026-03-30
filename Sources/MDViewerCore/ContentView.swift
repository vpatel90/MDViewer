import SwiftUI
import UniformTypeIdentifiers

public struct ContentView: View {
    @EnvironmentObject var manager: DocumentManager

    public init() {}

    public var body: some View {
        VStack(spacing: 0) {
            if manager.tabs.isEmpty {
                EmptyStateView()
                    .environmentObject(manager)
            } else {
                TabBarView()
                    .environmentObject(manager)

                if let tab = manager.selectedTab {
                    MarkdownWebView(content: tab.content)
                        .id(tab.id)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    Spacer()
                }
            }
        }
        .frame(minWidth: 600, minHeight: 400)
        .background(Color(nsColor: .textBackgroundColor))
        .onDrop(of: [.fileURL], isTargeted: nil, perform: handleDrop)
        .navigationTitle(manager.selectedTab?.filename ?? "MDViewer")
    }

    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        var handled = false
        for provider in providers {
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                guard let data = item as? Data,
                      let url = URL(dataRepresentation: data, relativeTo: nil),
                      ["md", "markdown", "mdown", "mkd", "mkdn"].contains(url.pathExtension.lowercased())
                else { return }

                Task { @MainActor in
                    manager.openFile(url: url)
                }
            }
            handled = true
        }
        return handled
    }
}
