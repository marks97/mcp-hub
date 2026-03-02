import SwiftUI

/// Root view: custom top bar spanning full width, with sidebar and detail below.
struct MainWindowView: View {
    @EnvironmentObject var appState: AppState
    @State private var isSpinning = false

    private var isLoading: Bool {
        appState.isDiscovering || appState.isRestarting
    }

    var body: some View {
        VStack(spacing: 0) {
            topBar
            Divider()
            HStack(spacing: 0) {
                SidebarView()
                    .frame(width: Theme.sidebarWidth)
                Divider()
                DetailView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
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

    // MARK: - Top Bar

    private var topBar: some View {
        HStack {
            claudeStatusIndicator
            Spacer()
            refreshButton
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Theme.windowBackground)
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
