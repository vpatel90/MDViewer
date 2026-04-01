import SwiftUI
import MDViewerCore

@main
struct MDViewerApp: App {
    @StateObject private var manager = DocumentManager()
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Window("MDViewer", id: "main") {
            ContentView()
                .environmentObject(manager)
                .onAppear {
                    appDelegate.manager = manager
                }
        }
        .defaultSize(width: 900, height: 700)
        .commands {
            // Remove "New Window" from the File menu
            CommandGroup(replacing: .newItem) {
                Button("Open...") {
                    manager.openFileDialog()
                }
                .keyboardShortcut("o")

                Divider()

                Button("Close Tab") {
                    if let id = manager.selectedTabID {
                        manager.closeTab(id: id)
                    }
                }
                .keyboardShortcut("w")
                .disabled(manager.tabs.isEmpty)
            }

            // Remove "New Window" from Window menu
            CommandGroup(replacing: .singleWindowList) {}

            CommandGroup(after: .textEditing) {
                Button("Find...") {
                    NotificationCenter.default.post(name: .init("MDViewerFind"), object: nil)
                }
                .keyboardShortcut("f")

                Button("Command Palette") {
                    NotificationCenter.default.post(name: .init("MDViewerCommandPalette"), object: nil)
                }
                .keyboardShortcut("k")
            }

            CommandGroup(after: .importExport) {
                Button("Export as PDF...") {
                    NotificationCenter.default.post(name: .init("MDViewerExportPDF"), object: manager.selectedTab?.filename)
                }
                .keyboardShortcut("e", modifiers: [.command, .shift])
                .disabled(manager.tabs.isEmpty)

                Button("Copy as HTML") {
                    NotificationCenter.default.post(name: .init("MDViewerCopyHTML"), object: nil)
                }
                .disabled(manager.tabs.isEmpty)
            }

            CommandGroup(after: .toolbar) {
                Button("Next Tab") {
                    manager.selectNextTab()
                }
                .keyboardShortcut("]", modifiers: .command)

                Button("Previous Tab") {
                    manager.selectPreviousTab()
                }
                .keyboardShortcut("[", modifiers: .command)

                Divider()

                ForEach(0..<9, id: \.self) { i in
                    Button("Tab \(i + 1)") {
                        manager.selectTab(at: i)
                    }
                    .keyboardShortcut(KeyEquivalent(Character(String(i + 1))), modifiers: .command)
                    .disabled(i >= manager.tabs.count)
                }
            }
        }
    }
}

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {
    var manager: DocumentManager?

    func application(_ application: NSApplication, open urls: [URL]) {
        // Bring existing window to front
        NSApp.windows.first { $0.isVisible }?.makeKeyAndOrderFront(nil)
        for url in urls {
            manager?.openFile(url: url)
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            NSApp.windows.first?.makeKeyAndOrderFront(nil)
        }
        return true
    }
}
