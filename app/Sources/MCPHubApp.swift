import SwiftUI

/// Entry point for the MCPHub menu bar application.
@main
struct MCPHubApp: App {
    @StateObject private var appState = AppState()

    var body: some Scene {
        MenuBarExtra {
            MenuBarView()
                .environmentObject(appState)
        } label: {
            Image(systemName: appState.isRestarting ? "arrow.triangle.2.circlepath" : "server.rack")
                .symbolRenderingMode(.hierarchical)
        }
        .menuBarExtraStyle(.window)
    }
}
