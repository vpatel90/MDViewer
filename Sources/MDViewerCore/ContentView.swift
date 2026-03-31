import SwiftUI
import UniformTypeIdentifiers

public struct ContentView: View {
    @EnvironmentObject var manager: DocumentManager
    @AppStorage("isDarkMode") private var isDarkMode = false
    @AppStorage("sidebarVisible") private var sidebarVisible = true

    public init() {}

    public var body: some View {
        NavigationSplitView {
            if manager.headings.isEmpty {
                VStack {
                    Spacer()
                    Text("No Headings")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            } else {
                TOCSidebarView(
                    headings: manager.headings,
                    activeHeadingID: manager.activeHeadingID,
                    onHeadingTap: { headingID in
                        NotificationCenter.default.post(name: .init("MDViewerScrollToHeading"), object: headingID)
                    }
                )
            }
        } detail: {
            VStack(spacing: 0) {
                if manager.tabs.isEmpty {
                    EmptyStateView()
                        .environmentObject(manager)
                } else {
                    HStack(spacing: 0) {
                        TabBarView()
                            .environmentObject(manager)

                        Spacer()

                        Toggle(isOn: $isDarkMode) {
                            Image(systemName: isDarkMode ? "moon.fill" : "sun.max.fill")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                        .toggleStyle(.switch)
                        .controlSize(.mini)
                        .padding(.trailing, 12)
                    }
                    .frame(height: 36)
                    .background(Color(nsColor: .windowBackgroundColor).opacity(0.95))
                    .overlay(Divider(), alignment: .bottom)

                    if let tab = manager.selectedTab {
                        MarkdownWebView(
                            content: tab.content,
                            isDarkMode: isDarkMode,
                            tabID: tab.id,
                            fileDir: tab.fileURL.deletingLastPathComponent().absoluteString,
                            onHeadingsUpdate: { headings in
                                manager.headings = headings
                            },
                            onActiveHeadingChange: { headingID in
                                manager.activeHeadingID = headingID
                            },
                            onStatsUpdate: { stats in
                                manager.documentStats = stats
                            }
                        )
                        .frame(maxWidth: .infinity, maxHeight: .infinity)

                        if let stats = manager.documentStats {
                            HStack {
                                Text(stats.description)
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                                Spacer()
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 4)
                            .background(Color(nsColor: .windowBackgroundColor).opacity(0.5))
                        }
                    } else {
                        Spacer()
                    }
                }
            }
        }
        .frame(minWidth: 600, minHeight: 400)
        .background(isDarkMode ? Color(nsColor: .windowBackgroundColor) : Color(nsColor: .textBackgroundColor))
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
