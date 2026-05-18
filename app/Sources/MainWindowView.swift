import SwiftUI

/// Root view: NavigationSplitView with foldable sidebar and unified toolbar.
struct MainWindowView: View {
    @EnvironmentObject var appState: AppState
    @State private var isSpinning = false
    @State private var columnVisibility: NavigationSplitViewVisibility = .doubleColumn

    private var isLoading: Bool {
        appState.isDiscovering || appState.anyProjectRestarting
    }

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView()
        } detail: {
            DetailView()
        }
        .navigationSplitViewStyle(.balanced)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                HStack(spacing: 12) {
                    claudeStatusMenu
                        .compositingGroup()
                        .shadow(color: .clear, radius: 0)
                    refreshButton
                        .compositingGroup()
                        .shadow(color: .clear, radius: 0)
                    Menu {
                        Button {
                            appState.showAddProject()
                        } label: {
                            Label("Add Project", systemImage: "folder.badge.plus")
                        }
                        Button {
                            appState.showingAddCloudInstance = true
                        } label: {
                            Label("Create Instance", systemImage: "cloud.fill")
                        }
                    } label: {
                        Label("Add", systemImage: "plus")
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .help("Add project or cloud instance")
                    .compositingGroup()
                    .shadow(color: .clear, radius: 0)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color(red: 254/255, green: 254/255, blue: 254/255))
                .clipShape(Capsule())
                .compositingGroup()
                .shadow(color: .clear, radius: 0)
            }
        }
        .frame(
            minWidth: Theme.windowMinWidth,
            minHeight: Theme.windowMinHeight
        )
        .sheet(isPresented: $appState.showingAddCloudInstance) {
            AddCloudInstanceSheet()
                .environmentObject(appState)
        }
        .onChange(of: isLoading) { _, loading in
            isSpinning = loading
        }
    }

    private var claudeStatusMenu: some View {
        Menu {
            // Global Claude actions
            Section("Shared Instance") {
                if appState.isClaudeRunning {
                    Button {
                        appState.applyAndRestart()
                    } label: {
                        Label("Restart Claude", systemImage: "arrow.clockwise")
                    }
                    .disabled(appState.isRestarting)
                } else {
                    Button {
                        appState.startClaude()
                    } label: {
                        Label("Start Claude", systemImage: "play.fill")
                    }
                    .disabled(appState.isRestarting)
                }
            }

            // Per-project isolated instance actions
            if let project = appState.selectedProject {
                let info = appState.projectInstances[project.id] ?? ProjectInstanceInfo()
                Section("Isolated (\(project.name))") {
                    if info.isRunning {
                        Button {
                            appState.restartClaudeForProject(project)
                        } label: {
                            Label("Restart Isolated", systemImage: "arrow.clockwise")
                        }
                        .disabled(info.isRestarting)
                    } else {
                        Button {
                            appState.launchClaudeForProject(project)
                        } label: {
                            Label("Start Isolated", systemImage: "play.fill")
                        }
                        .disabled(info.isRestarting)
                    }
                }
            }
        } label: {
            HStack(spacing: 6) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 8, height: 8)
                Text(statusText)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Theme.textSecondary)
            }
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    private var statusColor: Color {
        let info = selectedProjectInfo
        if info.isRunning || appState.isClaudeRunning {
            return Theme.green
        }
        return Theme.red
    }

    private var statusText: String {
        let info = selectedProjectInfo
        if info.isRunning {
            return "Isolated"
        }
        if appState.isClaudeRunning {
            return "Claude Running"
        }
        return "Claude Stopped"
    }

    private var selectedProjectInfo: ProjectInstanceInfo {
        guard let project = appState.selectedProject else { return ProjectInstanceInfo() }
        return appState.projectInstances[project.id] ?? ProjectInstanceInfo()
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
