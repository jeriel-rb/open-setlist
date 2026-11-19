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

        Settings {
            SettingsView()
                .environment(model)
        }
    }
}
