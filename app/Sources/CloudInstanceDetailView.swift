import SwiftUI

/// Detail view for a selected cloud instance.
struct CloudInstanceDetailView: View {
    let instance: CloudInstance
    @EnvironmentObject var appState: AppState
    @State private var showConnectPanel = false
    @State private var operationMessage: String?
    @State private var operationSuccess: Bool?
    @State private var showProjectPicker = false
    @State private var syncConfirmation: (projectId: String, direction: AppState.SyncDirection)? = nil
    @State private var automationTasks: [AppState.ScheduledTask] = []
    @State private var automationCrons: [String: String] = [:]
    @State private var automationSelected: Set<String> = []
    @State private var automationProjectName: String = ""
    @State private var automationMessage: String?

    private var runtimeInfo: CloudInstanceRuntimeInfo {
        appState.cloudInstanceRuntimeInfo[instance.id] ?? CloudInstanceRuntimeInfo()
    }

    var body: some View {
        VStack(spacing: 0) {
            instanceHeader

            Divider()

            ScrollView {
                VStack(spacing: 16) {
                    connectionConfigSection
                    pairedProjectsSection
                    automationsSection
                }
                .padding(20)
            }
        }
        .background(Theme.pampas.opacity(0.3))
        .sheet(isPresented: $showConnectPanel) {
            ConnectPanelSheet(instance: instance)
                .environmentObject(appState)
        }
        .onAppear {
            automationTasks = appState.discoverScheduledTasks()
        }
        .alert("Confirm Sync", isPresented: Binding(
            get: { syncConfirmation != nil },
            set: { if !$0 { syncConfirmation = nil } }
        )) {
            Button("Cancel", role: .cancel) { syncConfirmation = nil }
            Button(syncConfirmation?.direction == .push ? "Push" : "Pull") {
                if let conf = syncConfirmation,
                   let project = appState.projects.first(where: { $0.id == conf.projectId }) {
                    appState.syncProject(project, to: instance, direction: conf.direction) { s, m in
                        showOperationMessage(m, success: s)
                    }
                }
                syncConfirmation = nil
            }
        } message: {
            if let conf = syncConfirmation {
                let projectName = appState.projects.first(where: { $0.id == conf.projectId })?.name ?? "project"
                let dir = conf.direction == .push ? "Push to" : "Pull from"
                Text("\(dir) \(instance.name) for project \"\(projectName)\"?")
            }
        }
    }

    // MARK: - Header

    private var instanceHeader: some View {
        HStack(spacing: 12) {
            CloudInstanceAvatar(instance: instance, size: 36, isSelected: true)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Text(instance.name)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)

                    Text(instance.type.displayName)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Theme.blue)
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                }

                HStack(spacing: 6) {
                    Circle()
                        .fill(statusColor)
                        .frame(width: 7, height: 7)
                    Text(runtimeInfo.status.displayName)
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textTertiary)
                    if let ip = runtimeInfo.publicIP {
                        Text(ip)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(Theme.textTertiary)
                    }
                    setupPhaseBadge
                }
            }

            Spacer()

            if let msg = operationMessage {
                Text(msg)
                    .font(.system(size: 11))
                    .foregroundStyle(operationSuccess == true ? Theme.green : Theme.red)
                    .transition(.opacity)
            }

            actionButtons
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .background(Theme.windowBackground)
    }

    @ViewBuilder
    private var setupPhaseBadge: some View {
        // Only relevant once EC2 says "running" (cloud-init is host-side).
        // For SSH/Docker/Fargate types we don't render this badge.
        if instance.type == .ec2 && runtimeInfo.status == .running {
            let phase = runtimeInfo.setupPhase
            if phase != .unknown {
                let color: Color = phase == .ready ? Theme.green : Theme.orange
                HStack(spacing: 4) {
                    if phase.isProgress {
                        ProgressView()
                            .controlSize(.mini)
                            .frame(width: 8, height: 8)
                    } else {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 9))
                    }
                    Text(phase.displayName)
                        .font(.system(size: 10, weight: .medium))
                }
                .foregroundStyle(color)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(color.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 4))
            }
        }
    }

    private var statusColor: Color {
        switch runtimeInfo.status {
        case .running: return Theme.green
        case .starting, .stopping, .terminating: return Theme.orange
        case .stopped, .terminated: return Theme.red
        case .unknown: return Theme.midGray
        }
    }

    private var actionButtons: some View {
        HStack(spacing: 8) {
            // Launch Claude Desktop (placed before lifecycle buttons)
            launchClaudeButton

            // Start/Stop/Terminate — context-dependent
            switch instance.type {
            case .ssh:
                sshTestButton
            case .ec2:
                ec2ActionButtons
            case .fargate:
                fargateActionButtons
            case .docker:
                dockerActionButtons
            }

            // Connect button
            Button {
                showConnectPanel = true
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "link")
                    Text("Connect")
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
        }
    }

    private var sshTestButton: some View {
        Button {
            showOperationMessage(nil)
            appState.testSSHConnection(for: instance) { success, msg in
                showOperationMessage(msg, success: success)
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "bolt.horizontal")
                Text("Test")
            }
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.white)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Theme.green)
            .clipShape(RoundedRectangle(cornerRadius: Theme.smallCornerRadius))
        }
        .buttonStyle(.plain)
    }

    private var ec2ActionButtons: some View {
        HStack(spacing: 6) {
            if runtimeInfo.status == .starting {
                pendingButton("Starting...", color: Theme.green)
            } else if runtimeInfo.status == .stopping {
                pendingButton("Stopping...", color: Theme.orange)
            } else if runtimeInfo.status == .terminating {
                // Single button covers full terminate-cleanup window (~2–5 min)
                pendingButton("Terminating...", color: Theme.red)
            } else if runtimeInfo.status == .stopped || runtimeInfo.status == .unknown {
                lifecycleButton("Start", icon: "play.fill", color: Theme.green) {
                    appState.ec2Start(instance) { s, m in showOperationMessage(m, success: s) }
                }
            } else if runtimeInfo.status == .running {
                lifecycleButton("Stop", icon: "stop.fill", color: Theme.orange) {
                    appState.ec2Stop(instance) { s, m in showOperationMessage(m, success: s) }
                }
            }
            // Terminate button: hidden during any in-flight operation
            let inFlight: Set<CloudInstanceStatus> = [.starting, .stopping, .terminating, .terminated]
            if !inFlight.contains(runtimeInfo.status) {
                lifecycleButton("Terminate", icon: "xmark.circle", color: Theme.red) {
                    appState.ec2Terminate(instance) { s, m in showOperationMessage(m, success: s) }
                }
            }
        }
    }

    private var fargateActionButtons: some View {
        HStack(spacing: 6) {
            if runtimeInfo.status == .starting {
                pendingButton("Starting...", color: Theme.green)
            } else if runtimeInfo.status == .stopping {
                pendingButton("Stopping...", color: Theme.red)
            } else if runtimeInfo.status == .stopped || runtimeInfo.status == .unknown {
                lifecycleButton("Run", icon: "play.fill", color: Theme.green) {
                    appState.fargateRunTask(instance) { s, m in showOperationMessage(m, success: s) }
                }
            } else if runtimeInfo.status == .running {
                lifecycleButton("Stop", icon: "stop.fill", color: Theme.red) {
                    appState.fargateStopTask(instance) { s, m in showOperationMessage(m, success: s) }
                }
            }
        }
    }

    private func pendingButton(_ title: String, color: Color) -> some View {
        HStack(spacing: 4) {
            ProgressView()
                .controlSize(.mini)
                .frame(width: 10, height: 10)
            Text(title)
        }
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(.white)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(color.opacity(0.7))
        .clipShape(RoundedRectangle(cornerRadius: Theme.smallCornerRadius))
    }

    private var dockerActionButtons: some View {
        HStack(spacing: 6) {
            let hasContainer = !(instance.dockerConfig?.containerId.isEmpty ?? true)

            if runtimeInfo.status == .starting {
                pendingButton("Starting...", color: Theme.green)
            } else if runtimeInfo.status == .stopping {
                pendingButton("Stopping...", color: Theme.orange)
            } else {
                if !hasContainer {
                    lifecycleButton("Create", icon: "play.fill", color: Theme.green) {
                        appState.dockerRun(instance) { s, m in showOperationMessage(m, success: s) }
                    }
                }
                if hasContainer && (runtimeInfo.status == .stopped || runtimeInfo.status == .unknown) {
                    lifecycleButton("Start", icon: "play.fill", color: Theme.green) {
                        appState.dockerStart(instance) { s, m in showOperationMessage(m, success: s) }
                    }
                }
                if runtimeInfo.status == .running {
                    lifecycleButton("Stop", icon: "stop.fill", color: Theme.orange) {
                        appState.dockerStop(instance) { s, m in showOperationMessage(m, success: s) }
                    }
                }
                if hasContainer && runtimeInfo.status != .running {
                    lifecycleButton("Remove", icon: "trash", color: Theme.red) {
                        appState.dockerRemove(instance) { s, m in showOperationMessage(m, success: s) }
                    }
                }
            }
        }
    }

    private func lifecycleButton(_ title: String, icon: String, color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                Text(title)
            }
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.white)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(color)
            .clipShape(RoundedRectangle(cornerRadius: Theme.smallCornerRadius))
        }
        .buttonStyle(.plain)
    }

    private func showOperationMessage(_ message: String?, success: Bool = false) {
        withAnimation {
            operationMessage = message
            operationSuccess = success
        }
        if message != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
                withAnimation { operationMessage = nil }
            }
        }
    }

    @ViewBuilder
    private var launchClaudeButton: some View {
        let pairedProjects = appState.projects.filter { instance.pairedProjectIds.contains($0.id) }

        Menu {
            Section("Cloud-Isolated (separate app per instance)") {
                ForEach(pairedProjects) { project in
                    Button(project.name) {
                        appState.launchClaudeForCloudInstance(instance, project: project, mode: .cloudIsolated)
                        showOperationMessage("Launching Claude (cloud-isolated)...", success: true)
                    }
                }
                Button("Without project") {
                    appState.launchClaudeForCloudInstance(instance, mode: .cloudIsolated)
                    showOperationMessage("Launching Claude (cloud-isolated)...", success: true)
                }
            }
            if !pairedProjects.isEmpty {
                Section("Project-Isolated (uses project's own Claude)") {
                    ForEach(pairedProjects) { project in
                        Button(project.name) {
                            appState.launchClaudeForCloudInstance(instance, project: project, mode: .projectIsolated)
                            showOperationMessage("Launching Claude (project-isolated)...", success: true)
                        }
                    }
                }
            }
            Section("Global Claude") {
                Button("Open Global Claude with this SSH config") {
                    appState.launchClaudeForCloudInstance(instance, project: pairedProjects.first, mode: .global)
                    showOperationMessage("Launching global Claude...", success: true)
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "play.rectangle")
                Text("Claude Desktop")
                Image(systemName: "chevron.down")
                    .font(.system(size: 8))
            }
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.white)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Theme.orange)
            .clipShape(RoundedRectangle(cornerRadius: Theme.smallCornerRadius))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    // MARK: - Connection Config Section

    private var connectionConfigSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader("Connection Configuration")

            VStack(spacing: 10) {
                if instance.type == .ec2 || instance.type == .fargate {
                    awsCredentialsField
                }

                switch instance.type {
                case .ssh: sshConfigFields
                case .ec2: ec2ConfigFields
                case .fargate: fargateConfigFields
                case .docker: dockerConfigFields
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

    private var awsCredentialsField: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("AWS Credentials Source")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Theme.textSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            Picker("", selection: Binding(
                get: { instance.awsCredentialsProjectPath },
                set: { val in
                    var updated = instance
                    updated.awsCredentialsProjectPath = val
                    appState.updateCloudInstance(updated)
                    appState.pollSingleInstance(updated)
                }
            )) {
                Text("System (Keychain or ~/.aws/credentials)").tag("")
                ForEach(projectsWithAWSKeys, id: \.path) { project in
                    Text("Project: \(project.name)").tag(project.path)
                }
            }
            .labelsHidden()
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var projectsWithAWSKeys: [Project] {
        appState.projects.filter { project in
            for envPath in ["\(project.path)/.env", "\(project.path)/.claude/infra/.env"] {
                if let contents = try? String(contentsOfFile: envPath, encoding: .utf8),
                   contents.contains("AWS_ACCESS_KEY") {
                    return true
                }
            }
            return false
        }
    }

    @State private var editableInstance: CloudInstance? = nil

    private func binding<T>(for keyPath: WritableKeyPath<CloudInstance, T>) -> Binding<T> {
        Binding(
            get: { instance[keyPath: keyPath] },
            set: { newValue in
                var updated = instance
                updated[keyPath: keyPath] = newValue
                appState.updateCloudInstance(updated)
            }
        )
    }

    private var sshConfigFields: some View {
        Group {
            configField("Host", binding: sshBinding(\.host))
            HStack(spacing: 12) {
                configField("User", binding: sshBinding(\.user))
                configField("Port", value: Binding(
                    get: { String(instance.sshConfig?.port ?? 22) },
                    set: { val in
                        var updated = instance
                        if updated.sshConfig == nil { updated.sshConfig = SSHConfig() }
                        updated.sshConfig?.port = Int(val) ?? 22
                        appState.updateCloudInstance(updated)
                    }
                ), width: 80)
            }
            keyPathField("SSH Key", binding: sshBinding(\.keyPath))
        }
    }

    private var ec2ConfigFields: some View {
        Group {
            configField("Instance ID", binding: ec2Binding(\.instanceId))
            HStack(spacing: 12) {
                configField("Region", binding: ec2Binding(\.region))
                configField("Instance Type", binding: ec2Binding(\.instanceType))
            }
            configField("AMI", binding: ec2Binding(\.ami))
            HStack(spacing: 12) {
                configField("Key Pair", binding: ec2Binding(\.keyPair))
                configField("Security Group", binding: ec2Binding(\.securityGroup))
            }
            HStack(spacing: 12) {
                configField("SSH User", binding: ec2Binding(\.sshUser))
                keyPathField("SSH Key", binding: ec2Binding(\.sshKeyPath))
            }
        }
    }

    private var fargateConfigFields: some View {
        Group {
            HStack(spacing: 12) {
                configField("Cluster", binding: fargateBinding(\.cluster))
                configField("Region", binding: fargateBinding(\.region))
            }
            configField("Task Definition", binding: fargateBinding(\.taskDefinition))
            configField("Task ARN", binding: fargateBinding(\.taskArn))
            configField("Container Name", binding: fargateBinding(\.containerName))
            HStack(spacing: 12) {
                configField("SSH User", binding: fargateBinding(\.sshUser))
                keyPathField("SSH Key", binding: fargateBinding(\.sshKeyPath))
            }
        }
    }

    private var dockerConfigFields: some View {
        Group {
            configField("Image", binding: dockerBinding(\.imageName))
            HStack(spacing: 12) {
                configField("Container Name", binding: dockerBinding(\.containerName))
                configField("Container ID", binding: dockerBinding(\.containerId))
            }
            HStack(spacing: 12) {
                configField("SSH Port", value: Binding(
                    get: { String(instance.dockerConfig?.sshPort ?? 2222) },
                    set: { val in
                        var updated = instance
                        if updated.dockerConfig == nil { updated.dockerConfig = DockerConfig() }
                        updated.dockerConfig?.sshPort = Int(val) ?? 2222
                        appState.updateCloudInstance(updated)
                    }
                ), width: 80)
                configField("SSH User", binding: dockerBinding(\.sshUser))
            }
            keyPathField("SSH Key", binding: dockerBinding(\.sshKeyPath))
        }
    }

    // MARK: - Config Binding Helpers

    private func sshBinding(_ keyPath: WritableKeyPath<SSHConfig, String>) -> Binding<String> {
        Binding(
            get: { instance.sshConfig?[keyPath: keyPath] ?? "" },
            set: { newValue in
                var updated = instance
                if updated.sshConfig == nil { updated.sshConfig = SSHConfig() }
                updated.sshConfig?[keyPath: keyPath] = newValue
                appState.updateCloudInstance(updated)
            }
        )
    }

    private func ec2Binding(_ keyPath: WritableKeyPath<EC2Config, String>) -> Binding<String> {
        Binding(
            get: { instance.ec2Config?[keyPath: keyPath] ?? "" },
            set: { newValue in
                var updated = instance
                if updated.ec2Config == nil { updated.ec2Config = EC2Config() }
                updated.ec2Config?[keyPath: keyPath] = newValue
                appState.updateCloudInstance(updated)
            }
        )
    }

    private func fargateBinding(_ keyPath: WritableKeyPath<FargateConfig, String>) -> Binding<String> {
        Binding(
            get: { instance.fargateConfig?[keyPath: keyPath] ?? "" },
            set: { newValue in
                var updated = instance
                if updated.fargateConfig == nil { updated.fargateConfig = FargateConfig() }
                updated.fargateConfig?[keyPath: keyPath] = newValue
                appState.updateCloudInstance(updated)
            }
        )
    }

    private func dockerBinding(_ keyPath: WritableKeyPath<DockerConfig, String>) -> Binding<String> {
        Binding(
            get: { instance.dockerConfig?[keyPath: keyPath] ?? "" },
            set: { newValue in
                var updated = instance
                if updated.dockerConfig == nil { updated.dockerConfig = DockerConfig() }
                updated.dockerConfig?[keyPath: keyPath] = newValue
                appState.updateCloudInstance(updated)
            }
        )
    }

    // MARK: - Config Field Views

    private func configField(_ label: String, binding: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Theme.textSecondary)
            TextField("", text: binding)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12, design: .monospaced))
        }
    }

    private func configField(_ label: String, value: Binding<String>, width: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Theme.textSecondary)
            TextField("", text: value)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12, design: .monospaced))
                .frame(width: width)
        }
    }

    private func keyPathField(_ label: String, binding: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Theme.textSecondary)
            HStack(spacing: 6) {
                TextField("~/.ssh/id_rsa", text: binding)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12, design: .monospaced))
                Button {
                    let panel = NSOpenPanel()
                    panel.title = "Select SSH Key"
                    panel.canChooseFiles = true
                    panel.canChooseDirectories = false
                    panel.allowsMultipleSelection = false
                    panel.directoryURL = URL(fileURLWithPath: NSHomeDirectory() + "/.ssh")
                    if panel.runModal() == .OK, let url = panel.url {
                        binding.wrappedValue = url.path
                    }
                } label: {
                    Image(systemName: "folder")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textSecondary)
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - Paired Projects Section

    private var pairedProjectsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                sectionHeader("Paired Projects")
                Spacer()
                pairProjectMenu
            }

            if instance.pairedProjectIds.isEmpty {
                Text("No projects paired with this instance")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textTertiary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 20)
            } else {
                VStack(spacing: 8) {
                    ForEach(instance.pairedProjectIds, id: \.self) { projectId in
                        pairedProjectRow(projectId: projectId)
                    }
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

    private var pairProjectMenu: some View {
        let unpairedProjects = appState.projects.filter { !instance.pairedProjectIds.contains($0.id) }

        return Menu {
            if unpairedProjects.isEmpty {
                Text("All projects are paired")
            } else {
                ForEach(unpairedProjects) { project in
                    Button {
                        appState.pairProject(project.id, with: instance.id)
                    } label: {
                        Label(project.name, systemImage: "folder")
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "plus")
                Text("Pair Project")
            }
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(Theme.blue)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    private func pairedProjectRow(projectId: String) -> some View {
        let project = appState.projects.first(where: { $0.id == projectId })
        let name = project?.name ?? (projectId as NSString).lastPathComponent

        return HStack(spacing: 10) {
            Image(systemName: "folder.fill")
                .font(.system(size: 12))
                .foregroundStyle(Theme.orange)

            Text(name)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Theme.textPrimary)

            Spacer()

            // Deploy Automations
            Button {
                guard let proj = project else { return }
                let tasks = selectedAutomationTasks
                guard !tasks.isEmpty else {
                    let missing = automationSelected
                        .compactMap { id in automationTasks.first(where: { $0.id == id }) }
                        .filter { (automationCrons[$0.id] ?? "").isEmpty }
                        .map(\.name)
                    if !missing.isEmpty {
                        automationMessage = "Add a cron expression for: \(missing.joined(separator: ", "))"
                    } else {
                        automationMessage = "Select at least one automation"
                    }
                    showOperationMessage(automationMessage ?? "", success: false)
                    return
                }
                appState.deployAutomations(to: instance, tasks: tasks, projectName: proj.name) { s, m in
                    automationMessage = m
                    showOperationMessage(m, success: s)
                }
            } label: {
                HStack(spacing: 3) {
                    Image(systemName: "arrow.up.doc")
                    Text("Deploy")
                }
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(Theme.orange)
            }
            .buttonStyle(.plain)
            .disabled(project == nil || automationSelected.isEmpty)
            .help(automationSelected.isEmpty
                  ? "Check automations above first"
                  : "Deploy \(automationSelected.count) selected automation(s) to this project")

            // Sync (button = push, right-click = pull)
            Button {
                syncConfirmation = (projectId: projectId, direction: .push)
            } label: {
                HStack(spacing: 3) {
                    if runtimeInfo.isSyncing {
                        ProgressView()
                            .controlSize(.mini)
                            .frame(width: 10, height: 10)
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
            .help(syncTooltip)
            .contextMenu {
                Button {
                    syncConfirmation = (projectId: projectId, direction: .push)
                } label: {
                    Label("Push to Remote", systemImage: "arrow.up.circle")
                }
                Button {
                    syncConfirmation = (projectId: projectId, direction: .pull)
                } label: {
                    Label("Pull from Remote", systemImage: "arrow.down.circle")
                }
            }

            // Open in Instance
            Button {
                if let proj = project {
                    appState.launchClaudeForCloudInstance(instance, project: proj)
                    showOperationMessage("Launching Claude Desktop...", success: true)
                }
            } label: {
                HStack(spacing: 3) {
                    Image(systemName: "terminal")
                    Text("Open")
                }
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(Theme.orange)
            }
            .buttonStyle(.plain)
            .disabled(project == nil)

            Button {
                appState.unpairProject(projectId, from: instance.id)
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.red)
            }
            .buttonStyle(.plain)
            .help("Unpair project")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Theme.pampas.opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: Theme.smallCornerRadius))
    }

    private var syncTooltip: String {
        var parts = ["Push to remote (right-click for Pull)"]
        if let date = runtimeInfo.lastSyncDate {
            let fmt = DateFormatter()
            fmt.dateStyle = .short
            fmt.timeStyle = .medium
            parts.append("Last synced: \(fmt.string(from: date))")
        }
        if let error = runtimeInfo.lastSyncError {
            parts.append("Last error: \(error)")
        }
        return parts.joined(separator: "\n")
    }

    // MARK: - Automations Section

    private var automationsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                sectionHeader("Automations")
                Spacer()
                Button {
                    automationTasks = appState.discoverScheduledTasks()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textSecondary)
                }
                .buttonStyle(.plain)
                .help("Refresh task list")
            }

            if automationTasks.isEmpty {
                Text("No scheduled tasks found in ~/.claude/scheduled-tasks/")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textTertiary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 16)
            } else {
                VStack(spacing: 8) {
                    ForEach(automationTasks) { task in
                        automationTaskRow(task: task)
                    }
                }

                if instance.pairedProjectIds.isEmpty {
                    Text("Pair a project below to deploy these automations.")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textTertiary)
                        .padding(.top, 4)
                } else {
                    Text("Use the Deploy button on each paired project below to install these automations.")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textTertiary)
                        .padding(.top, 4)
                }

                if let msg = automationMessage {
                    Text(msg)
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textTertiary)
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

    /// Selected tasks with cron expressions, ready for deployment.
    private var selectedAutomationTasks: [(task: AppState.ScheduledTask, cronExpression: String)] {
        automationTasks
            .filter { automationSelected.contains($0.id) }
            .compactMap { task -> (task: AppState.ScheduledTask, cronExpression: String)? in
                guard let cron = automationCrons[task.id], !cron.isEmpty else { return nil }
                return (task: task, cronExpression: cron)
            }
    }

    private func automationTaskRow(task: AppState.ScheduledTask) -> some View {
        HStack(spacing: 10) {
            Toggle("", isOn: Binding(
                get: { automationSelected.contains(task.id) },
                set: { checked in
                    if checked { automationSelected.insert(task.id) }
                    else { automationSelected.remove(task.id) }
                }
            ))
            .labelsHidden()
            .toggleStyle(.checkbox)

            VStack(alignment: .leading, spacing: 2) {
                Text(task.name)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.textPrimary)
                if !task.description.isEmpty {
                    Text(task.description)
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.textTertiary)
                        .lineLimit(1)
                }
            }

            Spacer()

            TextField("cron (e.g. 0 9 * * *)", text: Binding(
                get: { automationCrons[task.id] ?? "" },
                set: { automationCrons[task.id] = $0 }
            ))
            .textFieldStyle(.roundedBorder)
            .font(.system(size: 11, design: .monospaced))
            .frame(width: 180)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Theme.pampas.opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: Theme.smallCornerRadius))
    }

    // MARK: - Helpers

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(Theme.textPrimary)
    }
}

// MARK: - Connect Panel Sheet

struct ConnectPanelSheet: View {
    let instance: CloudInstance
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var selectedTab = 0
    @State private var tunnelMessage: String?

    private var runtimeInfo: CloudInstanceRuntimeInfo {
        appState.cloudInstanceRuntimeInfo[instance.id] ?? CloudInstanceRuntimeInfo()
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Connect to \(instance.name)")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 16))
                        .foregroundStyle(Theme.textTertiary)
                }
                .buttonStyle(.plain)
            }
            .padding(20)

            Divider()

            // Tab picker
            Picker("", selection: $selectedTab) {
                Text("SSH").tag(0)
                Text("VNC").tag(1)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 20)
            .padding(.top, 16)

            // Content
            if selectedTab == 0 {
                sshTab
            } else {
                vncTab
            }

            Spacer()

            Divider()

            // Tunnel controls
            HStack {
                let tunnelActive = runtimeInfo.tunnelPID != nil

                Button {
                    if tunnelActive {
                        appState.closeTunnel(for: instance)
                        tunnelMessage = "Tunnel closed"
                    } else {
                        appState.openTunnel(for: instance) { success, msg in
                            tunnelMessage = msg
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Circle()
                            .fill(tunnelActive ? Theme.green : Theme.red)
                            .frame(width: 6, height: 6)
                        Text(tunnelActive ? "Close Tunnel" : "Open Tunnel")
                    }
                    .font(.system(size: 12, weight: .medium))
                }

                if tunnelActive {
                    Link(destination: URL(string: "http://localhost:6080/vnc.html")!) {
                        HStack(spacing: 3) {
                            Image(systemName: "arrow.up.right.square")
                                .font(.system(size: 10))
                            Text("Open noVNC")
                        }
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Theme.orange)
                    }
                    .help("http://localhost:6080/vnc.html")
                } else if let msg = tunnelMessage {
                    Text(msg)
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textTertiary)
                }

                Spacer()

                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(16)
        }
        .frame(width: 440, height: 380)
    }

    private var sshTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let cmd = appState.sshCommandString(for: instance) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("1. SSH into the host")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Theme.textSecondary)

                        copyableSnippet(cmd)
                    }
                } else {
                    Text("Configure SSH settings to see the connection command")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textTertiary)
                }

                // Docker + Claude instructions (only relevant when we provisioned a container)
                if instance.type == .ec2 || instance.type == .fargate || instance.type == .docker {
                    let containerName = dockerContainerNameForInstance
                    let projectFolder = firstPairedProjectFolder ?? "<project>"

                    VStack(alignment: .leading, spacing: 8) {
                        Text("2. Enter the container as the `node` user")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Theme.textSecondary)

                        copyableSnippet("docker exec -it -u node \(containerName) bash")

                        Text("`-u node` is required — the Claude CLI refuses to run as root.")
                            .font(.system(size: 10))
                            .foregroundStyle(Theme.textTertiary)
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Text("3. Run Claude on a synced project")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Theme.textSecondary)

                        copyableSnippet("cd /workspace/\(projectFolder)\nclaude --dangerously-skip-permissions")

                        Text("Synced project files live at /workspace/<project> inside the container.")
                            .font(.system(size: 10))
                            .foregroundStyle(Theme.textTertiary)
                    }
                }

                if let ip = runtimeInfo.publicIP {
                    HStack {
                        Text("Public IP:")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Theme.textSecondary)
                        Text(ip)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(Theme.textPrimary)
                            .textSelection(.enabled)
                    }
                }
            }
            .padding(20)
        }
    }

    /// Copyable code snippet block (multi-line aware).
    private func copyableSnippet(_ text: String) -> some View {
        HStack(alignment: .top) {
            Text(text)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(Theme.textPrimary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)

            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            } label: {
                Image(systemName: "doc.on.doc")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.blue)
            }
            .buttonStyle(.plain)
            .help("Copy to clipboard")
        }
        .padding(12)
        .background(Theme.pampas)
        .clipShape(RoundedRectangle(cornerRadius: Theme.smallCornerRadius))
    }

    /// Container name to use in `docker exec` instructions.
    /// Falls back to the conventional "claudehub" name we use in cloud-init.
    private var dockerContainerNameForInstance: String {
        switch instance.type {
        case .docker:
            let name = instance.dockerConfig?.containerName ?? ""
            return name.isEmpty ? "claudehub" : name
        case .fargate:
            let name = instance.fargateConfig?.containerName ?? ""
            return name.isEmpty ? "claudehub" : name
        default:
            return "claudehub"
        }
    }

    /// First paired project's folder name (last path component), used as a hint in instructions.
    private var firstPairedProjectFolder: String? {
        guard let firstId = instance.pairedProjectIds.first,
              let project = appState.projects.first(where: { $0.id == firstId }) else {
            return nil
        }
        return (project.path as NSString).lastPathComponent
    }

    private var vncTab: some View {
        VStack(alignment: .leading, spacing: 16) {
            let target = appState.resolveSSHTarget(for: instance)

            VStack(alignment: .leading, spacing: 8) {
                Text("VNC Connection")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.textSecondary)

                if runtimeInfo.tunnelPID != nil {
                    VStack(alignment: .leading, spacing: 10) {
                        Link(destination: URL(string: "http://localhost:6080/vnc.html")!) {
                            HStack(spacing: 6) {
                                Image(systemName: "safari")
                                    .font(.system(size: 12))
                                Text("Open in browser →")
                                    .font(.system(size: 12, weight: .medium))
                            }
                            .foregroundStyle(Theme.orange)
                        }

                        infoRow("URL", value: "http://localhost:6080/vnc.html")
                        infoRow("Native", value: "vnc://localhost:6080")
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Theme.pampas)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.smallCornerRadius))

                    Text("noVNC works in any browser. The vnc:// link is for native VNC clients (RealVNC, TigerVNC, macOS Screen Sharing).")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textTertiary)
                } else {
                    Text("Open an SSH tunnel first to access VNC. The tunnel forwards port 6080 for VNC access.")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textTertiary)
                        .padding(12)
                        .background(Theme.pampas)
                        .clipShape(RoundedRectangle(cornerRadius: Theme.smallCornerRadius))
                }
            }

            if let host = target?.host {
                HStack {
                    Text("Remote host:")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Theme.textSecondary)
                    Text(host)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(Theme.textPrimary)
                        .textSelection(.enabled)
                }
            }
        }
        .padding(20)
    }

    private func infoRow(_ label: String, value: String) -> some View {
        HStack {
            Text(label + ":")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Theme.textSecondary)
                .frame(width: 50, alignment: .leading)
            Text(value)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(Theme.textPrimary)
                .textSelection(.enabled)
        }
    }
}
