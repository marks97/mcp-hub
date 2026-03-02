import SwiftUI

/// Sidebar listing all registered projects with selection and context menus.
struct SidebarView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        List(selection: Binding(
            get: { appState.selectedProject },
            set: { project in
                if let project {
                    appState.selectProject(project)
                }
            }
        )) {
            Section("Projects") {
                ForEach(appState.projects) { project in
                    NavigationLink(value: project) {
                        ProjectRow(project: project)
                    }
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

    private var isSelected: Bool {
        appState.selectedProject?.id == project.id
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "folder.fill")
                .foregroundStyle(isSelected ? Theme.orange : Theme.textTertiary)
                .font(.system(size: 14))

            VStack(alignment: .leading, spacing: 2) {
                Text(project.name)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(isSelected ? Theme.textPrimary : Theme.textSecondary)
                    .lineLimit(1)

                Text(abbreviatedPath(project.path))
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 2)
    }

    private func abbreviatedPath(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if path.hasPrefix(home) {
            return "~" + path.dropFirst(home.count)
        }
        return path
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

            Text("Add a project folder that contains\n.claude/infra/.mcp.json")
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
