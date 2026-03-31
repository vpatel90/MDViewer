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
