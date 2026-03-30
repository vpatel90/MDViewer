import SwiftUI
import AppKit
import UniformTypeIdentifiers

@MainActor
public class DocumentManager: ObservableObject {
    @Published public var tabs: [DocumentTab] = []
    @Published public var selectedTabID: UUID?
    private var watchers: [UUID: FileWatcher] = [:]

    public init() {}

    public var selectedTab: DocumentTab? {
        guard let id = selectedTabID else { return nil }
        return tabs.first { $0.id == id }
    }

    public func openFile(url: URL) {
        if let existing = tabs.first(where: { $0.fileURL == url }) {
            selectedTabID = existing.id
            return
        }
        guard let content = try? String(contentsOf: url, encoding: .utf8) else { return }
        let tab = DocumentTab(fileURL: url, content: content)
        tabs.append(tab)
        selectedTabID = tab.id
        let tabID = tab.id
        watchers[tabID] = FileWatcher(url: url) { [weak self] in
            self?.reloadFile(id: tabID)
        }
    }

    public func closeTab(id: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        watchers[id]?.stop()
        watchers[id] = nil
        tabs.remove(at: index)
        if selectedTabID == id {
            if !tabs.isEmpty {
                let newIndex = min(index, tabs.count - 1)
                selectedTabID = tabs[newIndex].id
            } else {
                selectedTabID = nil
            }
        }
    }

    public func reloadFile(id: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        guard let content = try? String(contentsOf: tabs[index].fileURL, encoding: .utf8) else { return }
        tabs[index].content = content
    }

    public func openFileDialog() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [
            UTType(filenameExtension: "md") ?? .plainText,
            UTType(filenameExtension: "markdown") ?? .plainText
        ]
        panel.allowsMultipleSelection = true
        panel.message = "Choose Markdown files to open"
        if panel.runModal() == .OK {
            for url in panel.urls {
                openFile(url: url)
            }
        }
    }

    public func selectNextTab() {
        guard let currentID = selectedTabID,
              let index = tabs.firstIndex(where: { $0.id == currentID }),
              index + 1 < tabs.count else { return }
        selectedTabID = tabs[index + 1].id
    }

    public func selectPreviousTab() {
        guard let currentID = selectedTabID,
              let index = tabs.firstIndex(where: { $0.id == currentID }),
              index > 0 else { return }
        selectedTabID = tabs[index - 1].id
    }
}
