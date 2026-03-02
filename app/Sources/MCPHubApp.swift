import SwiftUI

/// Entry point for the Claude Hub application.
@main
struct ClaudeHubApp: App {
    @StateObject private var appState = AppState()

    var body: some Scene {
        WindowGroup {
            MainWindowView()
                .environmentObject(appState)
        }
        .defaultSize(width: 900, height: 600)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }
    }
}
