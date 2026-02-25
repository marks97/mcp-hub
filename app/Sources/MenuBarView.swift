import SwiftUI

/// Root view rendered inside the menu bar popover. Switches between the project list
/// (collapsed) and the server detail view (expanded) based on `isProjectExpanded`.
struct MenuBarView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        VStack(spacing: 0) {
            HeaderView()

            Divider()
                .background(Theme.cardBorder)

            if appState.isProjectExpanded && appState.selectedProject != nil {
                ProjectSelectorView()

                ScrollView {
                    VStack(spacing: 8) {
                        ForEach(appState.servers) { server in
                            ServerCardView(server: server)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                }
                .frame(maxHeight: 400)

                Divider()
                    .background(Theme.cardBorder)

                FooterView()
            } else {
                ProjectListView()
            }
        }
        .frame(width: Theme.panelWidth)
        .background(Theme.panelBackground)
    }
}

/// Top bar showing the MCPHub branding.
struct HeaderView: View {
    var body: some View {
        HStack {
            Image(systemName: "server.rack")
                .foregroundStyle(Theme.orange)
                .font(.system(size: 14, weight: .semibold))
            Text("MCPHub")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }
}

/// Placeholder shown when no projects have been added yet.
struct EmptyProjectsView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "folder.badge.plus")
                .font(.system(size: 28))
                .foregroundStyle(Theme.textTertiary)

            Text("No projects yet")
                .font(.system(size: 13))
                .foregroundStyle(Theme.textSecondary)

            AddProjectButton()
        }
        .padding(24)
    }
}

/// Reusable button that triggers the folder picker to add a new project.
struct AddProjectButton: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        Button {
            appState.showAddProject()
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "plus")
                Text("Add Project")
            }
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(Theme.orange)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Theme.orange.opacity(0.12))
            .clipShape(RoundedRectangle(cornerRadius: Theme.smallCornerRadius))
        }
        .buttonStyle(.plain)
    }
}

/// Compact breadcrumb showing the selected project name with a collapse chevron.
struct ProjectSelectorView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.2)) {
                appState.isProjectExpanded = false
            }
        } label: {
            HStack {
                Image(systemName: "folder.fill")
                    .foregroundStyle(Theme.orange)
                    .font(.system(size: 11))
                Text(appState.selectedProject?.name ?? "Select project")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                Spacer()
                Image(systemName: "chevron.up")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Theme.textTertiary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Theme.cardBackground)
        }
        .buttonStyle(.plain)
    }
}

/// Lists all registered projects with select, open-in-Finder, and remove actions.
struct ProjectListView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        VStack(spacing: 0) {
            ForEach(appState.projects) { project in
                Button {
                    appState.selectProject(project)
                    withAnimation(.easeInOut(duration: 0.2)) {
                        appState.isProjectExpanded = true
                    }
                } label: {
                    HStack {
                        Image(systemName: "folder.fill")
                            .foregroundStyle(project.id == appState.selectedProject?.id ? Theme.orange : Theme.textTertiary)
                            .font(.system(size: 11))
                        Text(project.name)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(project.id == appState.selectedProject?.id ? Theme.textPrimary : Theme.textSecondary)
                            .lineLimit(1)
                        Spacer()

                        HStack(spacing: 4) {
                            Button {
                                appState.openProject(project)
                            } label: {
                                Image(systemName: "folder")
                                    .font(.system(size: 10))
                                    .foregroundStyle(Theme.textTertiary)
                            }
                            .buttonStyle(.plain)
                            .help("Open in Finder")

                            Button {
                                appState.removeProject(project)
                            } label: {
                                Image(systemName: "xmark")
                                    .font(.system(size: 9))
                                    .foregroundStyle(Theme.textTertiary)
                            }
                            .buttonStyle(.plain)
                            .help("Remove project")
                        }

                        Image(systemName: "chevron.down")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(Theme.textTertiary)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                }
                .buttonStyle(.plain)

                if project.id != appState.projects.last?.id {
                    Divider().background(Theme.cardBorder).padding(.horizontal, 12)
                }
            }

            Divider().background(Theme.cardBorder)

            AddProjectButton()
                .padding(.vertical, 8)
        }
        .background(Theme.cardBackground)
    }
}

/// Bottom bar with "Scan Tools" and "Apply & Restart" / "Start Claude" actions.
struct FooterView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        HStack(spacing: 8) {
            Button {
                appState.discoverTools()
            } label: {
                HStack(spacing: 4) {
                    if appState.isDiscovering {
                        ProgressView()
                            .controlSize(.mini)
                    } else {
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .font(.system(size: 10))
                    }
                    Text(appState.isDiscovering ? "Scanning..." : "Scan Tools")
                        .font(.system(size: 11, weight: .medium))
                }
                .foregroundStyle(Theme.textSecondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Theme.cardBackground)
                .clipShape(RoundedRectangle(cornerRadius: Theme.smallCornerRadius))
            }
            .buttonStyle(.plain)
            .disabled(appState.isDiscovering)

            Spacer()

            Button {
                if appState.isClaudeRunning {
                    appState.applyAndRestart()
                } else {
                    appState.saveConfig()
                    appState.startClaude()
                }
            } label: {
                HStack(spacing: 4) {
                    if appState.isRestarting {
                        ProgressView()
                            .controlSize(.mini)
                            .tint(Theme.light)
                    } else if appState.isClaudeRunning {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 10))
                    } else {
                        Image(systemName: "play.fill")
                            .font(.system(size: 10))
                    }
                    Text(appState.isRestarting ? "Starting..." : appState.isClaudeRunning ? "Apply & Restart" : "Start Claude")
                        .font(.system(size: 11, weight: .medium))
                }
                .foregroundStyle(Theme.light)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(appState.isRestarting ? Theme.orange.opacity(0.6) : Theme.orange)
                .clipShape(RoundedRectangle(cornerRadius: Theme.smallCornerRadius))
            }
            .buttonStyle(.plain)
            .disabled(appState.isRestarting)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }
}
