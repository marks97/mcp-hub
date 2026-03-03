import SwiftUI

/// Sidebar listing all registered projects with selection and context menus.
/// Uses manual selection with custom row backgrounds to avoid macOS blue accent.
struct SidebarView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        List {
            Section("Projects") {
                ForEach(appState.projects) { project in
                    ProjectRow(project: project)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            appState.selectProject(project)
                        }
                        .listRowBackground(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(appState.selectedProject?.id == project.id
                                      ? Theme.orange.opacity(0.15)
                                      : Color.clear)
                        )
                        .contextMenu {
                            Button {
                                appState.openProject(project)
                            } label: {
                                Label("Open in Finder", systemImage: "folder")
                            }

                            Divider()

                            Button(role: .destructive) {
                                appState.removeProject(project)
                            } label: {
                                Label("Remove Project", systemImage: "trash")
                            }
                        }
                }
            }
        }
        .listStyle(.sidebar)
        .frame(minWidth: Theme.sidebarWidth)
        .overlay {
            if appState.projects.isEmpty {
                EmptySidebarView()
            }
        }
    }
}

/// A single project row in the sidebar list.
struct ProjectRow: View {
    let project: Project
    @EnvironmentObject var appState: AppState
    @State private var isHovered = false

    private var isSelected: Bool {
        appState.selectedProject?.id == project.id
    }

    private var instanceInfo: ProjectInstanceInfo {
        appState.projectInstances[project.id] ?? ProjectInstanceInfo()
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "folder.fill")
                .foregroundStyle(isSelected ? Theme.orange : Theme.textTertiary)
                .font(.system(size: 14))

            VStack(alignment: .leading, spacing: 2) {
                Text(project.name)
                    .font(.system(size: 13, weight: isSelected ? .semibold : .medium))
                    .foregroundStyle(isSelected ? Theme.textPrimary : Theme.textSecondary)
                    .lineLimit(1)

                Text(abbreviatedPath(project.path))
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(1)
            }

            Spacer()

            if isHovered || instanceInfo.isRestarting {
                HStack(spacing: 4) {
                    ProjectPlayButton(project: project)

                    Button {
                        appState.removeProject(project)
                    } label: {
                        Image(systemName: "trash")
                            .font(.system(size: 10))
                            .foregroundStyle(Theme.red)
                    }
                    .buttonStyle(.plain)
                    .help("Remove project")
                }
                .transition(.opacity.animation(.easeInOut(duration: 0.15)))
            }
        }
        .padding(.vertical, 2)
        .onHover { hovering in
            isHovered = hovering
        }
    }

    private func abbreviatedPath(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if path.hasPrefix(home) {
            return "~" + path.dropFirst(home.count)
        }
        return path
    }
}

/// Play/restart button for a project's Claude Desktop instance.
struct ProjectPlayButton: View {
    @EnvironmentObject var appState: AppState
    let project: Project

    private var info: ProjectInstanceInfo {
        appState.projectInstances[project.id] ?? ProjectInstanceInfo()
    }

    var body: some View {
        Button {
            if info.isRunning {
                appState.restartClaudeForProject(project)
            } else {
                appState.launchClaudeForProject(project)
            }
        } label: {
            if info.isRestarting {
                ProgressView()
                    .controlSize(.mini)
                    .frame(width: 14, height: 14)
            } else {
                Image(systemName: info.isRunning ? "arrow.clockwise" : "play.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(info.isRunning ? Theme.orange : Theme.green)
            }
        }
        .buttonStyle(.plain)
        .disabled(info.isRestarting)
        .help(info.isRunning ? "Restart Claude" : "Start Claude")
    }
}

/// Placeholder shown when no projects exist.
struct EmptySidebarView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "folder.badge.plus")
                .font(.system(size: 32))
                .foregroundStyle(Theme.textTertiary)

            Text("No projects yet")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Theme.textSecondary)

            Text("Add a project folder to manage\nits MCP servers")
                .font(.system(size: 12))
                .foregroundStyle(Theme.textTertiary)
                .multilineTextAlignment(.center)

            Button {
                appState.showAddProject()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "plus")
                    Text("Add Project")
                }
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(Theme.orange)
                .clipShape(RoundedRectangle(cornerRadius: Theme.smallCornerRadius))
            }
            .buttonStyle(.plain)
        }
        .padding(24)
    }
}
