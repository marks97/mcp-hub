import SwiftUI

/// Detail pane showing the selected project's MCP servers and tools.
struct DetailView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        Group {
            if let instance = appState.selectedCloudInstance {
                CloudInstanceDetailView(instance: instance)
            } else if let project = appState.selectedProject {
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
    @State private var showBadgePicker = false
    @State private var avatarHovered = false

    var body: some View {
        VStack(spacing: 0) {
            projectHeader

            Divider()

            ScrollView {
                LazyVStack(spacing: 12) {
                    if appState.servers.isEmpty {
                        emptyServersView
                            .frame(minHeight: 300)
                    } else {
                        ForEach(appState.servers) { server in
                            ServerCardView(server: server)
                        }
                    }
                    cloudInstancesSection
                }
                .padding(20)
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
            ProjectAvatar(project: project, size: 36, isSelected: true)
                .overlay(alignment: .bottomTrailing) {
                    if avatarHovered {
                        Image(systemName: "pencil.circle.fill")
                            .font(.system(size: 14))
                            .foregroundStyle(.white)
                            .background(Circle().fill(Theme.orange).frame(width: 14, height: 14))
                            .offset(x: 4, y: 4)
                            .transition(.opacity.animation(.easeInOut(duration: 0.15)))
                    }
                }
                .onHover { avatarHovered = $0 }
                .onTapGesture { showBadgePicker = true }
                .popover(isPresented: $showBadgePicker, arrowEdge: .bottom) {
                    BadgeIconPicker(project: project, isPresented: $showBadgePicker)
                        .environmentObject(appState)
                }

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
                .foregroundStyle(Theme.orange)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Theme.orange.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: Theme.smallCornerRadius))
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.smallCornerRadius)
                        .stroke(Theme.orange.opacity(0.3), lineWidth: 1)
                )
            }
            .buttonStyle(.plain)
        }
    }

    @ViewBuilder
    private var cloudActionButtons: some View {
        let paired = appState.cloudInstancesForProject(project)
        if !paired.isEmpty {
            if paired.count == 1, let inst = paired.first {
                Button {
                    appState.syncProject(project, to: inst, direction: .push) { _, _ in }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.up.circle")
                        Text("Deploy")
                    }
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Theme.green)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Theme.green.opacity(0.1))
                    .clipShape(RoundedRectangle(cornerRadius: Theme.smallCornerRadius))
                    .overlay(
                        RoundedRectangle(cornerRadius: Theme.smallCornerRadius)
                            .stroke(Theme.green.opacity(0.3), lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)

                Button {
                    appState.launchClaudeForCloudInstance(inst, project: project)
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "play.rectangle")
                        Text("Open in Instance")
                    }
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Theme.blue)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Theme.blue.opacity(0.1))
                    .clipShape(RoundedRectangle(cornerRadius: Theme.smallCornerRadius))
                    .overlay(
                        RoundedRectangle(cornerRadius: Theme.smallCornerRadius)
                            .stroke(Theme.blue.opacity(0.3), lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)
            } else {
                Menu {
                    Section("Deploy to...") {
                        ForEach(paired) { inst in
                            Button(inst.name) {
                                appState.syncProject(project, to: inst, direction: .push) { _, _ in }
                            }
                        }
                    }
                    Section("Open in Instance") {
                        ForEach(paired) { inst in
                            Button(inst.name) {
                                appState.launchClaudeForCloudInstance(inst, project: project)
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "cloud")
                        Text("Cloud")
                        Image(systemName: "chevron.down")
                            .font(.system(size: 8))
                    }
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Theme.blue)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Theme.blue.opacity(0.1))
                    .clipShape(RoundedRectangle(cornerRadius: Theme.smallCornerRadius))
                    .overlay(
                        RoundedRectangle(cornerRadius: Theme.smallCornerRadius)
                            .stroke(Theme.blue.opacity(0.3), lineWidth: 1)
                    )
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
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
                    .foregroundStyle(Theme.orange)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Theme.orange.opacity(0.1))
                    .clipShape(RoundedRectangle(cornerRadius: Theme.smallCornerRadius))
                    .overlay(
                        RoundedRectangle(cornerRadius: Theme.smallCornerRadius)
                            .stroke(Theme.orange.opacity(0.3), lineWidth: 1)
                    )
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

    // MARK: - Cloud Instances Section

    @ViewBuilder
    private var cloudInstancesSection: some View {
        let paired = appState.cloudInstancesForProject(project)
        let unpaired = appState.cloudInstances.filter { !$0.pairedProjectIds.contains(project.id) }

        // Hide entire card if no cloud instances paired with this project.
        if !paired.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Cloud Instances")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                    Spacer()
                    Menu {
                        if unpaired.isEmpty {
                            Text("All instances are paired")
                        } else {
                            ForEach(unpaired) { inst in
                                Button {
                                    appState.pairProject(project.id, with: inst.id)
                                } label: {
                                    Label(inst.name, systemImage: inst.type.iconName)
                                }
                            }
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "plus")
                            Text("Pair Instance")
                        }
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Theme.blue)
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                }

                VStack(spacing: 8) {
                    ForEach(paired) { inst in
                        ProjectCloudInstanceRow(project: project, instance: inst)
                    }
                }
            }
            .padding(16)
            .background(Theme.cardBackground)
            .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadius))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.cornerRadius)
                    .stroke(Theme.cardBorder, lineWidth: 1)
            )
        }
    }
}

/// Compact row showing a cloud instance + actions, rendered inside a project's detail view.
struct ProjectCloudInstanceRow: View {
    let project: Project
    let instance: CloudInstance
    @EnvironmentObject var appState: AppState

    private var runtimeInfo: CloudInstanceRuntimeInfo {
        appState.cloudInstanceRuntimeInfo[instance.id] ?? CloudInstanceRuntimeInfo()
    }

    private var statusColor: Color {
        switch runtimeInfo.status {
        case .running: return Theme.green
        case .starting, .stopping, .terminating: return Theme.orange
        case .stopped, .terminated: return Theme.red
        case .unknown: return Theme.midGray
        }
    }

    var body: some View {
        HStack(spacing: 10) {
            CloudInstanceAvatar(instance: instance, size: 22)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(instance.name)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Theme.textPrimary)
                    Text(instance.type.displayName)
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(Theme.blue)
                        .clipShape(RoundedRectangle(cornerRadius: 3))
                }
                HStack(spacing: 6) {
                    Circle().fill(statusColor).frame(width: 6, height: 6)
                    Text(runtimeInfo.status.displayName)
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.textTertiary)
                    if let ip = runtimeInfo.publicIP {
                        Text(ip)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(Theme.textTertiary)
                    }
                }
            }

            Spacer()

            // Sync (push, right-click for pull)
            Button {
                appState.syncProject(project, to: instance, direction: .push) { _, _ in }
            } label: {
                HStack(spacing: 3) {
                    if runtimeInfo.isSyncing {
                        ProgressView().controlSize(.mini).frame(width: 10, height: 10)
                    } else {
                        Image(systemName: "arrow.triangle.2.circlepath")
                    }
                    Text("Sync")
                }
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(Theme.green)
            }
            .buttonStyle(.plain)
            .disabled(runtimeInfo.isSyncing)
            .help("Push (right-click for Pull)")
            .contextMenu {
                Button {
                    appState.syncProject(project, to: instance, direction: .push) { _, _ in }
                } label: { Label("Push to Remote", systemImage: "arrow.up.circle") }
                Button {
                    appState.syncProject(project, to: instance, direction: .pull) { _, _ in }
                } label: { Label("Pull from Remote", systemImage: "arrow.down.circle") }
            }

            // Open in Instance
            Button {
                appState.launchClaudeForCloudInstance(instance, project: project)
            } label: {
                HStack(spacing: 3) {
                    Image(systemName: "terminal")
                    Text("Open")
                }
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(Theme.orange)
            }
            .buttonStyle(.plain)

            // Jump to instance (selects in sidebar so user can do lifecycle, automations, etc.)
            Button {
                appState.selectCloudInstance(instance)
            } label: {
                HStack(spacing: 3) {
                    Image(systemName: "arrow.up.right.square")
                    Text("Manage")
                }
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(Theme.blue)
            }
            .buttonStyle(.plain)
            .help("Open this instance's full detail view")

            Button {
                appState.unpairProject(project.id, from: instance.id)
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.red)
            }
            .buttonStyle(.plain)
            .help("Unpair instance")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Theme.pampas.opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: Theme.smallCornerRadius))
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
