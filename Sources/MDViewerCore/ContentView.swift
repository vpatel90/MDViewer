import SwiftUI
import UniformTypeIdentifiers

public struct ContentView: View {
    @EnvironmentObject var manager: DocumentManager
    @AppStorage("isDarkMode") private var isDarkMode = false
    @AppStorage("sidebarVisible") private var sidebarVisible = true
    @AppStorage("appTheme") private var appTheme = "default"
    @State private var showCommandPalette = false

    public init() {}

    public var body: some View {
        VStack(spacing: 0) {
            if manager.tabs.isEmpty {
                EmptyStateView()
                    .environmentObject(manager)
            } else {
                // Tab bar (full width, above everything)
                HStack(spacing: 0) {
                    TabBarView()
                        .environmentObject(manager)

                    Spacer()

                    // Sidebar toggle
                    Button(action: { withAnimation(.spring(.snappy)) { sidebarVisible.toggle() } }) {
                        Image(systemName: "sidebar.left")
                            .font(.system(size: 11))
                            .foregroundStyle(sidebarVisible ? .primary : .secondary)
                    }
                    .buttonStyle(.plain)
                    .padding(.trailing, 8)

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
                .background(.ultraThinMaterial)
                .overlay(Divider(), alignment: .bottom)

                // Content area: sidebar + webview side by side
                if let tab = manager.selectedTab {
                    HSplitView {
                        if sidebarVisible {
                            tocSidebar
                                .frame(minWidth: 180, idealWidth: 220, maxWidth: 300)
                        }

                        VStack(spacing: 0) {
                            MarkdownWebView(
                                content: tab.content,
                                isDarkMode: isDarkMode,
                                theme: appTheme,
                                tabID: tab.id,
                                fileDir: tab.fileURL.deletingLastPathComponent().absoluteString,
                                filename: tab.filename,
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
                            }
                        }
                    }
                } else {
                    Spacer()
                }
            }
        }
        .animation(.spring(.smooth), value: manager.tabs.isEmpty)
        .frame(minWidth: 600, minHeight: 400)
        .background(isDarkMode ? Color(nsColor: .windowBackgroundColor) : Color(nsColor: .textBackgroundColor))
        .onDrop(of: [.fileURL], isTargeted: nil, perform: handleDrop)
        .navigationTitle(manager.selectedTab?.filename ?? "MDViewer")
        .overlay {
            if showCommandPalette {
                ZStack {
                    Color.black.opacity(0.3)
                        .ignoresSafeArea()
                        .onTapGesture { showCommandPalette = false }

                    VStack {
                        CommandPaletteView(
                            isPresented: $showCommandPalette,
                            items: buildCommandPaletteItems()
                        )
                        .padding(.top, 80)
                        Spacer()
                    }
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .init("MDViewerCommandPalette"))) { _ in
            showCommandPalette.toggle()
        }
    }

    private var tocSidebar: some View {
        ScrollViewReader { proxy in
            List {
                if manager.headings.isEmpty {
                    Text("No Headings")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                } else {
                    ForEach(manager.headings) { heading in
                        Button(action: {
                            NotificationCenter.default.post(name: .init("MDViewerScrollToHeading"), object: heading.id)
                        }) {
                            Text(heading.text)
                                .font(.system(size: fontSize(for: heading.level),
                                              weight: heading.level <= 2 ? .semibold : .regular))
                                .foregroundStyle(heading.id == manager.activeHeadingID ? .primary : .secondary)
                                .lineLimit(2)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(.plain)
                        .padding(.leading, CGFloat(max(0, heading.level - 1)) * 12)
                        .padding(.vertical, 2)
                        .listRowBackground(
                            heading.id == manager.activeHeadingID
                                ? Color.accentColor.opacity(0.1)
                                : Color.clear
                        )
                        .id(heading.id)
                    }
                }
            }
            .listStyle(.sidebar)
            .onChange(of: manager.activeHeadingID) { _, newID in
                if let id = newID {
                    withAnimation { proxy.scrollTo(id, anchor: .center) }
                }
            }
        }
    }

    private func fontSize(for level: Int) -> CGFloat {
        switch level {
        case 1: return 13
        case 2: return 12.5
        default: return 12
        }
    }

    private func buildCommandPaletteItems() -> [CommandPaletteItem] {
        var items: [CommandPaletteItem] = []

        // Headings
        for heading in manager.headings {
            items.append(CommandPaletteItem(
                icon: "text.alignleft",
                title: heading.text,
                shortcut: nil,
                action: {
                    NotificationCenter.default.post(name: .init("MDViewerScrollToHeading"), object: heading.id)
                }
            ))
        }

        // Tab switching
        for tab in manager.tabs {
            if tab.id != manager.selectedTabID {
                items.append(CommandPaletteItem(
                    icon: "square.on.square",
                    title: "Switch to \(tab.filename)",
                    shortcut: nil,
                    action: { manager.selectedTabID = tab.id }
                ))
            }
        }

        // Themes
        for themeName in ["default", "serif", "ink", "paper"] {
            let displayName = themeName.capitalized
            items.append(CommandPaletteItem(
                icon: "paintpalette",
                title: "Theme: \(displayName)",
                shortcut: nil,
                action: { appTheme = themeName }
            ))
        }

        // Actions
        items.append(CommandPaletteItem(icon: "doc", title: "Open File...", shortcut: "\u{2318}O",
            action: { manager.openFileDialog() }))
        items.append(CommandPaletteItem(icon: isDarkMode ? "sun.max.fill" : "moon.fill",
            title: isDarkMode ? "Switch to Light Mode" : "Switch to Dark Mode", shortcut: nil,
            action: { isDarkMode.toggle() }))
        items.append(CommandPaletteItem(icon: "sidebar.left",
            title: sidebarVisible ? "Hide Sidebar" : "Show Sidebar", shortcut: nil,
            action: { withAnimation(.spring(.snappy)) { sidebarVisible.toggle() } }))
        items.append(CommandPaletteItem(icon: "arrow.down.doc", title: "Export as PDF...", shortcut: "\u{21E7}\u{2318}E",
            action: { NotificationCenter.default.post(name: .init("MDViewerExportPDF"), object: manager.selectedTab?.filename) }))
        items.append(CommandPaletteItem(icon: "doc.richtext", title: "Copy as HTML", shortcut: nil,
            action: { NotificationCenter.default.post(name: .init("MDViewerCopyHTML"), object: nil) }))

        return items
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
