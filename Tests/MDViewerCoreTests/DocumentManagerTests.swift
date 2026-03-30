import Foundation
import Testing
@testable import MDViewerCore

@MainActor
struct DocumentManagerTests {

    private func makeTempFile(_ name: String, content: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
        let url = dir.appendingPathComponent(name)
        try content.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func cleanup(_ urls: URL...) {
        for url in urls {
            try? FileManager.default.removeItem(at: url)
        }
    }

    @Test func openFile_addsTabAndSelectsIt() throws {
        let manager = DocumentManager()
        let file = try makeTempFile("test1.md", content: "# Hello")
        defer { cleanup(file) }

        manager.openFile(url: file)

        #expect(manager.tabs.count == 1)
        #expect(manager.tabs[0].content == "# Hello")
        #expect(manager.tabs[0].filename == "test1.md")
        #expect(manager.selectedTabID == manager.tabs[0].id)
    }

    @Test func openFile_duplicateSelectsExisting() throws {
        let manager = DocumentManager()
        let file = try makeTempFile("test2.md", content: "# Dup")
        defer { cleanup(file) }

        manager.openFile(url: file)
        let firstID = manager.tabs[0].id
        manager.openFile(url: file)

        #expect(manager.tabs.count == 1)
        #expect(manager.selectedTabID == firstID)
    }

    @Test func openMultipleFiles() throws {
        let manager = DocumentManager()
        let f1 = try makeTempFile("a.md", content: "A")
        let f2 = try makeTempFile("b.md", content: "B")
        defer { cleanup(f1, f2) }

        manager.openFile(url: f1)
        manager.openFile(url: f2)

        #expect(manager.tabs.count == 2)
        #expect(manager.selectedTabID == manager.tabs[1].id)
    }

    @Test func closeTab_removesAndSelectsPrevious() throws {
        let manager = DocumentManager()
        let f1 = try makeTempFile("c.md", content: "C")
        let f2 = try makeTempFile("d.md", content: "D")
        defer { cleanup(f1, f2) }

        manager.openFile(url: f1)
        manager.openFile(url: f2)
        let secondID = manager.tabs[1].id

        manager.closeTab(id: secondID)

        #expect(manager.tabs.count == 1)
        #expect(manager.selectedTabID == manager.tabs[0].id)
    }

    @Test func closeLastTab_clearsSelection() throws {
        let manager = DocumentManager()
        let file = try makeTempFile("e.md", content: "E")
        defer { cleanup(file) }

        manager.openFile(url: file)
        manager.closeTab(id: manager.tabs[0].id)

        #expect(manager.tabs.isEmpty)
        #expect(manager.selectedTabID == nil)
    }

    @Test func reloadFile_updatesContent() throws {
        let manager = DocumentManager()
        let file = try makeTempFile("f.md", content: "Original")
        defer { cleanup(file) }

        manager.openFile(url: file)
        let tabID = manager.tabs[0].id

        try "Updated".write(to: file, atomically: true, encoding: .utf8)
        manager.reloadFile(id: tabID)

        #expect(manager.tabs[0].content == "Updated")
    }

    @Test func selectedTab_returnsCorrectTab() throws {
        let manager = DocumentManager()
        let f1 = try makeTempFile("g.md", content: "G")
        let f2 = try makeTempFile("h.md", content: "H")
        defer { cleanup(f1, f2) }

        manager.openFile(url: f1)
        manager.openFile(url: f2)

        #expect(manager.selectedTab?.content == "H")

        manager.selectedTabID = manager.tabs[0].id
        #expect(manager.selectedTab?.content == "G")
    }
}
