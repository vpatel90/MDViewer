import AppKit
import SwiftUI
import UniformTypeIdentifiers

public struct ContentView: View {
    @EnvironmentObject var manager: DocumentManager
    @EnvironmentObject var authManager: GoogleAuthManager
    @AppStorage("isDarkMode") private var isDarkMode = false
    @AppStorage("sidebarVisible") private var sidebarVisible = true
    @AppStorage("appTheme") private var appTheme = "default"
    @State private var showCommandPalette = false
    @State private var showGDocURLInput = false
    @State private var gdocURLInput = ""

    private var docsService: GoogleDocsService { GoogleDocsService(auth: authManager) }
    private var converter: MarkdownConverter { MarkdownConverter() }

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
        .sheet(isPresented: $showGDocURLInput) {
            VStack(spacing: 16) {
                Text("Import from Google Doc")
                    .font(.headline)
                TextField("Paste Google Doc URL...", text: $gdocURLInput)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 400)
                    .onSubmit { handleImportWithURL() }
                HStack {
                    Button("Cancel") {
                        gdocURLInput = ""
                        showGDocURLInput = false
                    }
                    .keyboardShortcut(.cancelAction)
                    Button("Import") { handleImportWithURL() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(gdocURLInput.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .padding(24)
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

        // Google Docs
        items.append(CommandPaletteItem(
            icon: "arrow.down.doc.fill",
            title: "Import from Google Doc",
            shortcut: nil,
            action: { handleImportFromGoogleDoc() }
        ))
        if manager.selectedTab != nil {
            items.append(CommandPaletteItem(
                icon: "arrow.up.doc.fill",
                title: "Push to Google Doc",
                shortcut: nil,
                action: { handlePushToGoogleDoc() }
            ))
        }
        if authManager.isAuthenticated {
            items.append(CommandPaletteItem(
                icon: "person.crop.circle.badge.xmark",
                title: "Disconnect Google Account",
                shortcut: nil,
                action: { Task { try? await authManager.disconnect() } }
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

    // MARK: - Google Docs Handlers

    private func handleImportFromGoogleDoc() {
        // If current tab has a gdoc frontmatter link, offer to update
        if let tab = manager.selectedTab,
           let gdocURL = tab.gdocURL,
           let docID = FrontmatterParser.extractDocID(from: gdocURL) {
            let alert = NSAlert()
            alert.messageText = "Update from Google Doc?"
            alert.informativeText = "This will replace the current file content with the latest version from Google Docs."
            alert.addButton(withTitle: "Update")
            alert.addButton(withTitle: "Cancel")
            alert.alertStyle = .informational
            guard alert.runModal() == .alertFirstButtonReturn else { return }

            Task {
                do {
                    try await ensureAuthenticated()
                    let html = try await docsService.fetchDocHTML(docID: docID)
                    let markdown = converter.htmlToMarkdown(html)
                    let updated = FrontmatterParser.setField("gdoc", value: gdocURL, in: markdown)
                    try updated.write(to: tab.fileURL, atomically: true, encoding: .utf8)
                } catch {
                    showError(error)
                }
            }
        } else {
            gdocURLInput = ""
            showGDocURLInput = true
        }
    }

    private func handleImportWithURL() {
        let urlString = gdocURLInput.trimmingCharacters(in: .whitespaces)
        guard let docID = FrontmatterParser.extractDocID(from: urlString) else {
            let alert = NSAlert()
            alert.messageText = "Invalid Google Doc URL"
            alert.informativeText = "Please paste a valid Google Docs URL (e.g. https://docs.google.com/document/d/…/edit)."
            alert.alertStyle = .warning
            alert.runModal()
            return
        }

        showGDocURLInput = false

        Task {
            do {
                try await ensureAuthenticated()
                let html = try await docsService.fetchDocHTML(docID: docID)
                let markdown = converter.htmlToMarkdown(html)
                let withFrontmatter = FrontmatterParser.setField("gdoc", value: urlString, in: markdown)

                let panel = NSSavePanel()
                panel.allowedContentTypes = [.init(filenameExtension: "md")!]
                panel.nameFieldStringValue = "Imported Doc.md"
                guard panel.runModal() == .OK, let saveURL = panel.url else { return }

                try withFrontmatter.write(to: saveURL, atomically: true, encoding: .utf8)
                manager.openFile(url: saveURL)
            } catch {
                showError(error)
            }
        }
    }

    private func handlePushToGoogleDoc() {
        guard let tab = manager.selectedTab else { return }
        let parsed = FrontmatterParser.parse(tab.content)
        let body = parsed.body

        if let gdocURL = parsed.fields["gdoc"],
           let docID = FrontmatterParser.extractDocID(from: gdocURL) {
            // Update existing doc
            let alert = NSAlert()
            alert.messageText = "Push to Google Doc?"
            alert.informativeText = "This will update the linked Google Doc with the current markdown content."
            alert.addButton(withTitle: "Push")
            alert.addButton(withTitle: "Cancel")
            alert.alertStyle = .informational
            guard alert.runModal() == .alertFirstButtonReturn else { return }

            Task {
                do {
                    try await ensureAuthenticated()
                    let html = converter.markdownToHTML(body)
                    try await docsService.updateDoc(docID: docID, html: html)
                } catch {
                    showError(error)
                }
            }
        } else {
            // Create new doc
            let alert = NSAlert()
            alert.messageText = "Create new Google Doc?"
            alert.informativeText = "This will create a new Google Doc from the current markdown content and link it via frontmatter."
            alert.addButton(withTitle: "Create")
            alert.addButton(withTitle: "Cancel")
            alert.alertStyle = .informational
            guard alert.runModal() == .alertFirstButtonReturn else { return }

            Task {
                do {
                    try await ensureAuthenticated()
                    let html = converter.markdownToHTML(body)
                    let docName = tab.filename.replacingOccurrences(of: ".md", with: "")
                    let newURL = try await docsService.createDoc(name: docName, html: html)
                    let updated = FrontmatterParser.setField("gdoc", value: newURL, in: tab.content)
                    try updated.write(to: tab.fileURL, atomically: true, encoding: .utf8)
                } catch {
                    showError(error)
                }
            }
        }
    }

    private func ensureAuthenticated() async throws {
        if !authManager.isAuthenticated {
            try await authManager.authenticate()
        }
    }

    private func showError(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = "Error"
        alert.informativeText = error.localizedDescription
        alert.alertStyle = .critical
        alert.runModal()
    }
}
