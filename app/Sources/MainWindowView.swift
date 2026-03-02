import SwiftUI

/// Root view: NavigationSplitView with foldable sidebar and unified toolbar.
struct MainWindowView: View {
    @EnvironmentObject var appState: AppState
    @State private var isSpinning = false
    @State private var columnVisibility: NavigationSplitViewVisibility = .doubleColumn

    private var isLoading: Bool {
        appState.isDiscovering || appState.isRestarting
    }

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView()
        } detail: {
            DetailView()
        }
        .navigationSplitViewStyle(.balanced)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                claudeStatusIndicator
                refreshButton

                Button {
                    appState.showAddProject()
                } label: {
                    Label("Add Project", systemImage: "plus")
                }
                .help("Add a project folder")
            }
        }
        .frame(
            minWidth: Theme.windowMinWidth,
            minHeight: Theme.windowMinHeight
        )
        .onChange(of: isLoading) { _, loading in
            isSpinning = loading
        }
    }

    private var claudeStatusIndicator: some View {
        Button {
            if appState.isClaudeRunning {
                appState.applyAndRestart()
            } else {
                appState.startClaude()
            }
        } label: {
            HStack(spacing: 6) {
                Circle()
                    .fill(appState.isClaudeRunning ? Theme.green : Theme.red)
                    .frame(width: 8, height: 8)
                Text(appState.isClaudeRunning ? "Claude Running" : "Claude Stopped")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Theme.textSecondary)
            }
            .padding(.vertical, 4)
        }
        .buttonStyle(.plain)
        .disabled(appState.isRestarting)
        .help(appState.isClaudeRunning ? "Click to restart Claude Desktop" : "Click to start Claude Desktop")
    }

    private var refreshButton: some View {
        Button {
            appState.discoverTools()
        } label: {
            Image(systemName: "arrow.triangle.2.circlepath")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(isLoading ? Theme.orange : Theme.textSecondary)
                .rotationEffect(.degrees(isSpinning ? 360 : 0))
                .animation(
                    isSpinning
                        ? .linear(duration: 1).repeatForever(autoreverses: false)
                        : .default,
                    value: isSpinning
                )
        }
        .buttonStyle(.plain)
        .disabled(isLoading || appState.selectedProject == nil)
        .help("Scan tools")
    }
}
