// MicroFreakLibrarianApp.swift — @main SwiftUI App (UX §18.1).
//
// FreakLibrarianApp owns AppModel and the global keyboard commands (UX §13.8:
// fully supported, never required).

import SwiftUI

@main
struct FreakLibrarianApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
        }
        .commands {
            CommandGroup(replacing: .undoRedo) {
                Button("Undo Overwrite") { model.undoLast() }
                    .keyboardShortcut("z", modifiers: .command)
                    .disabled(!model.undoStack.canUndo)
                Button("Redo Overwrite") { model.redoLast() }
                    .keyboardShortcut("z", modifiers: [.command, .shift])
                    .disabled(!model.undoStack.canRedo)
            }
            CommandMenu("Device") {
                // Same busy gate as the toolbar buttons — ⌘B during a
                // running backup must not enqueue a second full pass.
                Button("Refresh Names") { _ = model.refreshNames() }
                    .keyboardShortcut("r", modifiers: .command)
                    .disabled(!model.connection.hasDevice
                              || model.operations.exclusiveLongOp != nil)
                Button("Back Up Now") { model.backUpNow() }
                    .keyboardShortcut("b", modifiers: .command)
                    .disabled(!model.connection.hasDevice
                              || model.operations.exclusiveLongOp != nil)
            }
            CommandMenu("Go") {
                Button("Device") { model.sidebar = .device }
                    .keyboardShortcut("1", modifiers: .command)
                Button("Library") { model.sidebar = .library(tag: nil) }
                    .keyboardShortcut("2", modifiers: .command)
                Button("Collections") { model.sidebar = .collections }
                    .keyboardShortcut("3", modifiers: .command)
                Button("Sync") { model.sidebar = .sync }
                    .keyboardShortcut("4", modifiers: .command)
                Button("Backups") { model.sidebar = .backups }
                    .keyboardShortcut("5", modifiers: .command)
            }
        }
    }
}
