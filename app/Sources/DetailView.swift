import SwiftUI

/// Detail pane showing the selected project's MCP servers and tools.
struct DetailView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        Group {
            if let project = appState.selectedProject {
                ProjectDetailView(project: project)
            } else {
                EmptyDetailView()
            }
        }
    }
}

/// Full detail view for a selected project.
struct ProjectDetailView: View {
    let project: Project
    @EnvironmentObject var appState: AppState
    @State private var showAddServer = false
    @State private var showMarketplace = false

    var body: some View {
        VStack(spacing: 0) {
            projectHeader

            Divider()

            if appState.servers.isEmpty {
                emptyServersView
            } else {
                ScrollView {
                    LazyVStack(spacing: 12) {
                        ForEach(appState.servers) { server in
                            ServerCardView(server: server)
                        }
                    }
                    .padding(20)
                }
            }
        }
        .background(Theme.pampas.opacity(0.3))
        .sheet(isPresented: $showAddServer) {
            AddServerSheet()
                .environmentObject(appState)
        }
        .sheet(isPresented: $showMarketplace) {
            MarketplaceSheet()
                .environmentObject(appState)
        }
    }

    private var projectHeader: some View {
        HStack(spacing: 12) {
            Image(systemName: "folder.fill")
                .font(.system(size: 20))
                .foregroundStyle(Theme.orange)

            VStack(alignment: .leading, spacing: 2) {
                Text(project.name)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)

                Text(abbreviatedPath(project.path))
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textTertiary)
            }

            Spacer()

            if appState.isDiscovering {
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Scanning tools...")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textSecondary)
                }
                .transition(.opacity.animation(.easeIn(duration: 0.15)))
            }

            actionButtons
            serverSummary
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .background(Theme.windowBackground)
    }

    private var actionButtons: some View {
        HStack(spacing: 8) {
            Button {
                showAddServer = true
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "plus")
                    Text("Add Server")
                }
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Theme.orange)
                .clipShape(RoundedRectangle(cornerRadius: Theme.smallCornerRadius))
            }
            .buttonStyle(.plain)

            Button {
                showMarketplace = true
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "square.grid.2x2")
                    Text("Marketplace")
                }
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Theme.blue)
                .clipShape(RoundedRectangle(cornerRadius: Theme.smallCornerRadius))
            }
            .buttonStyle(.plain)
        }
    }

    private var serverSummary: some View {
        let enabledServers = appState.servers.filter(\.enabled).count
        let totalTools = appState.servers.reduce(0) { $0 + $1.tools.count }
        let enabledTools = appState.servers.reduce(0) { $0 + $1.enabledToolCount }

        return HStack(spacing: 16) {
            summaryBadge(
                label: "Servers",
                value: "\(enabledServers)/\(appState.servers.count)",
                color: Theme.green
            )
            if totalTools > 0 {
                summaryBadge(
                    label: "Tools",
                    value: "\(enabledTools)/\(totalTools)",
                    color: Theme.orange
                )
            }
        }
    }

    private func summaryBadge(label: String, value: String, color: Color) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.system(size: 13, weight: .semibold, design: .monospaced))
                .foregroundStyle(color)
            Text(label)
                .font(.system(size: 10))
                .foregroundStyle(Theme.textTertiary)
        }
    }

    private var emptyServersView: some View {
        VStack(spacing: 16) {
            Spacer()

            Image(systemName: "server.rack")
                .font(.system(size: 36))
                .foregroundStyle(Theme.textTertiary)

            Text("No MCP servers configured")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Theme.textSecondary)

            Text("Add a server manually or browse the marketplace")
                .font(.system(size: 12))
                .foregroundStyle(Theme.textTertiary)

            HStack(spacing: 12) {
                Button {
                    showAddServer = true
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "plus")
                        Text("Add Server")
                    }
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Theme.orange)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.smallCornerRadius))
                }
                .buttonStyle(.plain)

                Button {
                    showMarketplace = true
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "square.grid.2x2")
                        Text("Marketplace")
                    }
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Theme.blue)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.smallCornerRadius))
                }
                .buttonStyle(.plain)
            }

            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private func abbreviatedPath(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if path.hasPrefix(home) {
            return "~" + path.dropFirst(home.count)
        }
        return path
    }
}

/// Placeholder when no project is selected.
struct EmptyDetailView: View {
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "sidebar.left")
                .font(.system(size: 40))
                .foregroundStyle(Theme.textTertiary)

            Text("Select a project")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(Theme.textSecondary)

            Text("Choose a project from the sidebar to manage its MCP servers and tools.")
                .font(.system(size: 13))
                .foregroundStyle(Theme.textTertiary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 300)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.pampas.opacity(0.3))
    }
}
