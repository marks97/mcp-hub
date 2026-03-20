import SwiftUI

/// Sidebar listing all registered projects.
/// Uses ScrollView instead of List to fully bypass AppKit's blue selection highlight.
struct SidebarView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Section header
            Text("Projects")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.textTertiary)
                .textCase(.uppercase)
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 8)

            if appState.projects.isEmpty {
                EmptySidebarView()
            } else {
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(appState.projects) { project in
                            ProjectRow(project: project)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.bottom, 8)
                }
            }
        }
        .frame(minWidth: Theme.sidebarWidth)
        .background(Theme.sidebarBackground)
    }
}

/// A single project row in the sidebar.
struct ProjectRow: View {
    let project: Project
    @EnvironmentObject var appState: AppState
    @State private var isHovered = false
    @State private var showBadgePicker = false

    private var isSelected: Bool {
        appState.selectedProject?.id == project.id
    }

    private var instanceInfo: ProjectInstanceInfo {
        appState.projectInstances[project.id] ?? ProjectInstanceInfo()
    }

    var body: some View {
        HStack(spacing: 8) {
            ProjectAvatar(project: project, size: 24, isSelected: isSelected)
                .overlay(alignment: .bottomTrailing) {
                    if isHovered {
                        Image(systemName: "pencil.circle.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(.white)
                            .background(Circle().fill(Theme.orange).frame(width: 10, height: 10))
                            .offset(x: 3, y: 3)
                            .transition(.opacity.animation(.easeInOut(duration: 0.15)))
                    }
                }
                .onTapGesture { showBadgePicker = true }

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
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isSelected ? Theme.orange.opacity(0.15) : isHovered ? Theme.midGray.opacity(0.15) : Color.clear)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            appState.selectProject(project)
        }
        .onHover { hovering in
            isHovered = hovering
        }
        .contextMenu {
            Button {
                appState.openProject(project)
            } label: {
                Label("Open in Finder", systemImage: "folder")
            }

            Button {
                showBadgePicker = true
            } label: {
                Label("Badge Icon...", systemImage: "app.badge")
            }

            Divider()

            Button(role: .destructive) {
                appState.removeProject(project)
            } label: {
                Label("Remove Project", systemImage: "trash")
            }
        }
        .popover(isPresented: $showBadgePicker, arrowEdge: .trailing) {
            BadgeIconPicker(project: project, isPresented: $showBadgePicker)
                .environmentObject(appState)
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
            Spacer()

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

            Spacer()
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Auto-generated avatar for a project: shows badge icon, custom image, or a letter initial.
struct ProjectAvatar: View {
    let project: Project
    let size: CGFloat
    var isSelected: Bool = false

    @EnvironmentObject var appState: AppState

    var body: some View {
        Group {
            switch project.badgeIcon {
            case .sfSymbol(let name):
                Image(systemName: name)
                    .font(.system(size: size * 0.5, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: size, height: size)
                    .background(Circle().fill(isSelected ? Theme.orange : Theme.textSecondary))
            case .customImage(let filename):
                if let img = appState.loadBadgeImage(filename: filename) {
                    Image(nsImage: img)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: size, height: size)
                        .clipShape(Circle())
                } else {
                    letterAvatar
                }
            case .none:
                letterAvatar
            }
        }
    }

    private var letterAvatar: some View {
        let letter = String(project.name.prefix(1)).uppercased()
        return Text(letter)
            .font(.system(size: size * 0.5, weight: .bold, design: .rounded))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(Circle().fill(isSelected ? Theme.orange : Theme.textSecondary))
    }
}
