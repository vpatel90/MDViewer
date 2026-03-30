import SwiftUI
import MDViewerCore

@main
struct MDViewerApp: App {
    @StateObject private var manager = DocumentManager()
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(manager)
                .onAppear {
                    appDelegate.manager = manager
                }
        }
        .defaultSize(width: 900, height: 700)
        .commands {
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
        for url in urls {
            manager?.openFile(url: url)
        }
    }
}
