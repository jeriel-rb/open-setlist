import SwiftUI

@main
struct SetlistApp: App {
    @State private var model = AppModel()
    @State private var player = Player()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(model)
                .environment(player)
        }
        .windowToolbarStyle(.unified)
        .commands { HelpCommands() }

        Window("Setlist Help", id: HelpCommands.windowID) {
            HelpView()
        }
        .windowResizability(.contentMinSize)

        Settings {
            SettingsView()
                .environment(model)
        }
    }
}

/// Help → Setlist Help (⌘?) opens the app's own help window instead of the empty system one.
struct HelpCommands: Commands {
    static let windowID = "help"
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .help) {
            Button("Setlist Help") { openWindow(id: Self.windowID) }
                .keyboardShortcut("?", modifiers: .command)
        }
    }
}
