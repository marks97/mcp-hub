import Foundation
import Combine
import AppKit
import Security
import os.log

private let logger = Logger(subsystem: "com.claudehub", category: "AppState")

/// Central application state managing projects, MCP server configurations,
/// and Claude Desktop lifecycle (global or per-project isolation).
class AppState: ObservableObject {
    @Published var projects: [Project] = []
    @Published var selectedProject: Project?
    @Published var servers: [ServerState] = []
    @Published var isDiscovering = false
    @Published var settings = AppSettings()

    // Global Claude state (used when isolation is OFF)
    @Published var isRestarting = false
    @Published var isClaudeRunning = false

    // Per-project Claude state (used when isolation is ON)
    @Published var projectInstances: [String: ProjectInstanceInfo] = [:]

    // Cloud instances
    @Published var cloudInstances: [CloudInstance] = []
    @Published var selectedCloudInstance: CloudInstance?
    @Published var cloudInstanceRuntimeInfo: [UUID: CloudInstanceRuntimeInfo] = [:]
    @Published var showingAddCloudInstance = false

    // Docker images
    @Published var dockerImages: [DockerImage] = []
    @Published var showingDockerImageEditor = false
    /// Image currently being edited (nil = create new).
    @Published var editingDockerImage: DockerImage?
    /// Paused state of the Create Instance sheet, restored when it reopens
    /// after the user finishes adding/editing an image. nil = no pending draft.
    @Published var cloudInstanceDraft: CloudInstanceDraft?

    var anyProjectRestarting: Bool {
        isRestarting || projectInstances.values.contains { $0.isRestarting }
    }

    private let gatewayPath: String
    private var claudePollingTimer: Timer?
    private var lastDesktopConfigWriteDate: Date?
    private var pollingTickCount: Int = 0

    private enum Config {
        static let claudeBundleId = "com.anthropic.claudefordesktop"
        static let userDefaultsKey = "savedProjects"
        static let settingsKey = "appSettings"
        static let cloudInstancesKey = "savedCloudInstances"
        static let dockerImagesKey = "savedDockerImages"
        static let mcpConfigPath = ".claude/infra/.mcp.json"
        static let gatewayConfigPath = ".claude/infra/gateway.config.json"
        static let envFilePath = ".claude/infra/.env"
        static let pollingInterval: TimeInterval = 3.0
        static let pollStep: TimeInterval = 0.5
        static let gracefulTerminationAttempts = 20
        static let forceTerminationAttempts = 10
        static let launchPollAttempts = 30
        static let processSettleDelay: TimeInterval = 5.0
        static let toolDiscoveryTimeout: TimeInterval = 15.0
        static let cloudPollingTicks = 10 // poll cloud instances every 10th tick (~30s)
        static let awsKeychainService = "com.claudehub.aws"
    }

    /// The run-mcp.sh script template. Resolves the user's login shell PATH
    /// (GUI apps inherit a minimal PATH), sources .env, expands $VAR refs, then exec's.
    static let runMcpScript: String = [
        "#!/bin/bash",
        "",
        "# Resolve full user PATH (GUI apps have a minimal PATH)",
        #"eval \"$(/bin/zsh -ilc 'printf \"export PATH=\\\"%s\\\"\" \"$PATH\"' 2>/dev/null)\""#,
        "",
        #"SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)""#,
        #"ENV_FILE="$SCRIPT_DIR/../.env""#,
        "",
        #"if [ -f "$ENV_FILE" ]; then"#,
        "  set -a",
        #"  source "$ENV_FILE""#,
        "  set +a",
        "fi",
        "",
        "# Expand $VAR references in arguments",
        "EXPANDED_ARGS=()",
        #"for arg in "$@"; do"#,
        #"  if [[ "$arg" == *'$'* ]]; then"#,
        #"    EXPANDED_ARGS+=("$(eval printf '%s' "$arg")")"#,
        "  else",
        #"    EXPANDED_ARGS+=("$arg")"#,
        "  fi",
        "done",
        "",
        "# Polyfill globalThis.crypto for Node environments where it's missing",
        #"export NODE_OPTIONS=\"--require ${SCRIPT_DIR}/crypto-shim.cjs ${NODE_OPTIONS:-}\""#,
        "",
        #"exec "${EXPANDED_ARGS[@]}""#,
    ].joined(separator: "\n")

    /// Polyfill for globalThis.crypto, preloaded via NODE_OPTIONS --require.
    static let cryptoShimScript = """
    // Polyfill globalThis.crypto for environments where it's missing
    if (typeof globalThis.crypto === 'undefined') {
      const { webcrypto } = require('crypto');
      globalThis.crypto = webcrypto;
    }
    """

    init() {
        self.gatewayPath = Self.findGatewayPath()
        loadSettings()
        isClaudeRunning = findClaudeApp() != nil
        loadProjects()
        loadCloudInstances()
        loadDockerImages()
        seedBundledDockerImage()
        if let first = projects.first {
            selectedProject = first
            loadServers(for: first)
        }
        startClaudePolling()

        // Trigger an immediate status check for cloud instances so they don't show "Unknown" for 30s
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.pollCloudInstanceStatuses()
        }
    }

    deinit {
        claudePollingTimer?.invalidate()
    }

    // MARK: - Settings

    func loadSettings() {
        if let data = UserDefaults.standard.data(forKey: Config.settingsKey),
           let saved = try? JSONDecoder().decode(AppSettings.self, from: data) {
            settings = saved
        }
    }

    func saveSettings() {
        if let data = try? JSONEncoder().encode(settings) {
            UserDefaults.standard.set(data, forKey: Config.settingsKey)
        }
        cleanupStaleWrappers()
    }

    // MARK: - Claude Polling

    private func startClaudePolling() {
        claudePollingTimer = Timer.scheduledTimer(withTimeInterval: Config.pollingInterval, repeats: true) { [weak self] _ in
            guard let self else { return }

            self.pollingTickCount += 1

            // Global Claude check
            if !self.isRestarting {
                let running = self.findClaudeApp() != nil
                if running != self.isClaudeRunning {
                    self.isClaudeRunning = running
                }
            }

            // Per-project isolated instance checks
            for (projectId, info) in self.projectInstances {
                // Auto-clear stuck isRestarting after 30 seconds
                if info.isRestarting,
                   let since = info.restartingSince,
                   Date().timeIntervalSince(since) > 30 {
                    logger.warning("polling: force-clearing stuck isRestarting for \(projectId) after 30s")
                    let settingsDir = self.projects.first(where: { $0.id == projectId })
                        .map { self.claudeSettingsDir(for: $0) }
                    let foundPid = settingsDir.flatMap { self.findClaudePid(settingsDir: $0) }
                    let running = foundPid.map { kill($0, 0) == 0 } ?? false
                    self.projectInstances[projectId] = ProjectInstanceInfo(
                        isRunning: running,
                        pid: foundPid
                    )
                    continue
                }
                guard !info.isRestarting, let pid = info.pid else { continue }
                let running = kill(pid, 0) == 0
                if running != info.isRunning {
                    self.projectInstances[projectId] = ProjectInstanceInfo(
                        isRunning: running,
                        isRestarting: false,
                        pid: running ? pid : nil
                    )
                }
            }

            // Sync MCP servers and tool states with Claude Desktop
            if let project = self.selectedProject {
                self.syncFromDesktopConfig(for: project)

                // Ensure tools in session files are enabled
                // (catches newly created sessions where tools default to disabled)
                self.enableAllToolsInSessions(settingsDir: self.claudeSettingsDir(for: project))
            }

            // Cloud instance status polling (every 10th tick, ~30s)
            if self.pollingTickCount % Config.cloudPollingTicks == 0 {
                self.pollCloudInstanceStatuses()
            }

            // Check SSH tunnel liveness
            for (id, info) in self.cloudInstanceRuntimeInfo {
                if let pid = info.tunnelPID {
                    if kill(pid, 0) != 0 {
                        self.cloudInstanceRuntimeInfo[id]?.tunnelPID = nil
                    }
                }
            }
        }
    }

    // MARK: - Gateway Resolution

    private static func findGatewayPath() -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = [
            "\(home)/Documents/claude-hub/gateway",
            "\(home)/claude-hub/gateway",
            Bundle.main.resourcePath.map { "\($0)/gateway" } ?? "",
        ]
        for path in candidates {
            if FileManager.default.fileExists(atPath: "\(path)/index.js") {
                return path
            }
        }
        return candidates[0]
    }

    // MARK: - Project Management

    func loadProjects() {
        if let data = UserDefaults.standard.data(forKey: Config.userDefaultsKey),
           let saved = try? JSONDecoder().decode([Project].self, from: data) {
            projects = saved
        }
    }

    func saveProjects() {
        if let data = try? JSONEncoder().encode(projects) {
            UserDefaults.standard.set(data, forKey: Config.userDefaultsKey)
        }
    }

    // MARK: - Badge Icons

    /// Directory for storing custom badge icon images.
    static var badgeIconsDir: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let dir = "\(home)/Library/Application Support/ClaudeHub/BadgeIcons"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Saves a custom image and returns its filename.
    func saveBadgeImage(_ image: NSImage) -> String? {
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return nil }
        let filename = "\(UUID().uuidString).png"
        let path = "\(Self.badgeIconsDir)/\(filename)"
        do {
            try png.write(to: URL(fileURLWithPath: path))
            return filename
        } catch {
            return nil
        }
    }

    /// Loads a custom badge image by filename.
    func loadBadgeImage(filename: String) -> NSImage? {
        NSImage(contentsOfFile: "\(Self.badgeIconsDir)/\(filename)")
    }

    /// Removes a custom badge image file.
    private func removeBadgeImage(filename: String) {
        try? FileManager.default.removeItem(atPath: "\(Self.badgeIconsDir)/\(filename)")
    }

    /// Updates a project's badge and regenerates its wrapper icon.
    func updateBadgeIcon(for project: Project, badge: BadgeIcon) {
        // Clean up old custom image if switching away
        if case .customImage(let oldFile) = project.badgeIcon, badge != project.badgeIcon {
            removeBadgeImage(filename: oldFile)
        }

        guard let index = projects.firstIndex(where: { $0.id == project.id }) else { return }
        projects[index].badgeIcon = badge
        saveProjects()

        // Regenerate wrapper icon if one exists
        let displayName = settings.isolationDisplayName(for: projects[index].name)
        let wrapperPath = "\(Self.wrappersDir)/\(displayName).app"
        let fm = FileManager.default
        if fm.fileExists(atPath: wrapperPath) {
            let iconDest = "\(wrapperPath)/Contents/Resources/AppIcon.icns"
            try? IconCompositor.generateIcon(
                badge: badge,
                outputPath: iconDest,
                badgeImageLoader: { self.loadBadgeImage(filename: $0) }
            )
            // Touch Info.plist to invalidate Dock icon cache
            let plistPath = "\(wrapperPath)/Contents/Info.plist"
            try? fm.setAttributes([.modificationDate: Date()], ofItemAtPath: plistPath)
        }

        if selectedProject?.id == project.id {
            selectedProject = projects[index]
        }
    }

    func showAddProject() {
        let panel = NSOpenPanel()
        panel.title = "Select a project folder"
        panel.message = "Choose a folder to manage MCP servers for"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false

        guard panel.runModal() == .OK, let url = panel.url else { return }
        addProject(path: url.path)
    }

    /// Adds a project at the given path, scaffolding the .claude structure if needed.
    func addProject(path: String) {
        let normalizedPath = path.hasSuffix("/") ? String(path.dropLast()) : path
        let name = (normalizedPath as NSString).lastPathComponent

        guard FileManager.default.fileExists(atPath: normalizedPath) else { return }

        let mcpConfigPath = "\(normalizedPath)/\(Config.mcpConfigPath)"
        if !FileManager.default.fileExists(atPath: mcpConfigPath) {
            scaffoldClaudeStructure(at: normalizedPath)
        }

        let project = Project(name: name, path: normalizedPath)
        if !projects.contains(where: { $0.path == normalizedPath }) {
            projects.append(project)
            saveProjects()
        }
        selectedProject = project
        loadServers(for: project)
    }

    /// Creates the .claude directory structure for a project, including
    /// the env-injecting wrapper script so secrets from .env reach MCP servers.
    private func scaffoldClaudeStructure(at projectPath: String) {
        let fm = FileManager.default
        let claudeDir = "\(projectPath)/.claude"

        let dirs = [
            "\(claudeDir)/infra",
            "\(claudeDir)/infra/scripts",
            "\(claudeDir)/agents",
            "\(claudeDir)/docs",
            "\(claudeDir)/rules",
            "\(claudeDir)/skills",
            "\(claudeDir)/memories",
        ]
        for dir in dirs {
            try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
        }

        // .mcp.json
        let mcpPath = "\(claudeDir)/infra/.mcp.json"
        if !fm.fileExists(atPath: mcpPath) {
            let mcpJson: [String: Any] = ["mcpServers": [String: Any]()]
            if let data = try? JSONSerialization.data(withJSONObject: mcpJson, options: [.prettyPrinted, .sortedKeys]) {
                try? data.write(to: URL(fileURLWithPath: mcpPath))
            }
        }

        // run-mcp.sh — resolves PATH, sources .env, expands $VAR refs, then exec's
        let runMcpPath = "\(claudeDir)/infra/scripts/run-mcp.sh"
        let runMcpScript = Self.runMcpScript
        // Always update to latest version of the script
        try? runMcpScript.write(toFile: runMcpPath, atomically: true, encoding: .utf8)
        var attrs = (try? fm.attributesOfItem(atPath: runMcpPath)) ?? [:]
        attrs[.posixPermissions] = 0o755
        try? fm.setAttributes(attrs, ofItemAtPath: runMcpPath)

        // crypto-shim.cjs — polyfills globalThis.crypto for MCP servers
        let shimPath = "\(claudeDir)/infra/scripts/crypto-shim.cjs"
        try? Self.cryptoShimScript.write(toFile: shimPath, atomically: true, encoding: .utf8)

        // Empty .env for secrets
        let envPath = "\(claudeDir)/infra/.env"
        if !fm.fileExists(atPath: envPath) {
            try? "".write(toFile: envPath, atomically: true, encoding: .utf8)
        }

        // CLAUDE.md
        let claudeMdPath = "\(claudeDir)/CLAUDE.md"
        if !fm.fileExists(atPath: claudeMdPath) {
            try? "".write(toFile: claudeMdPath, atomically: true, encoding: .utf8)
        }

        // .claudehubignore — default patterns for file sync exclusion
        let ignorePath = "\(projectPath)/.claudehubignore"
        if !fm.fileExists(atPath: ignorePath) {
            let header = "# Patterns for files NOT to sync to remote cloud instances.\n# Same syntax as .gitignore.\n\n"
            let defaults = SyncConfig.defaultExcludes.joined(separator: "\n")
            try? (header + defaults + "\n").write(toFile: ignorePath, atomically: true, encoding: .utf8)
        }
    }

    /// Removes a project, terminates its Claude instance if running, cleans up wrapper, and updates selection.
    func removeProject(_ project: Project) {
        // Terminate isolated instance if running
        if let info = projectInstances[project.id], let pid = info.pid, info.isRunning {
            DispatchQueue.global(qos: .utility).async { [weak self] in
                self?.doTerminateClaude(pid: pid)
            }
        }
        projectInstances.removeValue(forKey: project.id)

        // Clean up custom badge image if present
        if case .customImage(let filename) = project.badgeIcon {
            removeBadgeImage(filename: filename)
        }

        // Remove wrapper .app if it exists
        let displayName = settings.isolationDisplayName(for: project.name)
        let wrapperPath = "\(Self.wrappersDir)/\(displayName).app"
        try? FileManager.default.removeItem(atPath: wrapperPath)

        projects.removeAll { $0.id == project.id }
        saveProjects()
        if selectedProject?.id == project.id {
            selectedProject = projects.first
            if let p = selectedProject {
                loadServers(for: p)
            } else {
                servers = []
            }
        }
    }

    func selectProject(_ project: Project) {
        selectedCloudInstance = nil
        selectedProject = project
        loadServers(for: project)

        // Ensure desktop config has our servers, then initialize sync state
        writeDesktopConfig(for: project)
        syncFromDesktopConfig(for: project)
    }

    // MARK: - Cloud Instance Management

    func loadCloudInstances() {
        if let data = UserDefaults.standard.data(forKey: Config.cloudInstancesKey),
           let saved = try? JSONDecoder().decode([CloudInstance].self, from: data) {
            cloudInstances = saved
        }
    }

    func saveCloudInstances() {
        if let data = try? JSONEncoder().encode(cloudInstances) {
            UserDefaults.standard.set(data, forKey: Config.cloudInstancesKey)
        }
    }

    func addCloudInstance(_ instance: CloudInstance) {
        cloudInstances.append(instance)
        saveCloudInstances()
        selectCloudInstance(instance)
    }

    func removeCloudInstance(_ instance: CloudInstance) {
        closeTunnel(for: instance)
        cloudInstanceRuntimeInfo.removeValue(forKey: instance.id)
        cloudInstances.removeAll { $0.id == instance.id }
        saveCloudInstances()
        if selectedCloudInstance?.id == instance.id {
            selectedCloudInstance = cloudInstances.first
        }
    }

    func updateCloudInstance(_ instance: CloudInstance) {
        guard let index = cloudInstances.firstIndex(where: { $0.id == instance.id }) else { return }
        cloudInstances[index] = instance
        saveCloudInstances()
        if selectedCloudInstance?.id == instance.id {
            selectedCloudInstance = cloudInstances[index]
        }
    }

    func selectCloudInstance(_ instance: CloudInstance) {
        selectedProject = nil
        servers = []
        selectedCloudInstance = instance
        // Trigger an immediate status check for this instance so it doesn't show "Unknown"
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.pollSingleInstance(instance)
        }
    }

    // MARK: - Docker Image Management

    func loadDockerImages() {
        if let data = UserDefaults.standard.data(forKey: Config.dockerImagesKey),
           let saved = try? JSONDecoder().decode([DockerImage].self, from: data) {
            dockerImages = saved
        }
    }

    func saveDockerImages() {
        if let data = try? JSONEncoder().encode(dockerImages) {
            UserDefaults.standard.set(data, forKey: Config.dockerImagesKey)
        }
    }

    /// Ensures the bundled built-in image exists (and is up-to-date) in the
    /// user's image list. Idempotent: called on every app launch.
    func seedBundledDockerImage() {
        let bundled = DockerImageBuilder.bundledDefaultImage()
        if let idx = dockerImages.firstIndex(where: { $0.id == bundled.id }) {
            // Refresh built-in content (Dockerfile/entrypoint may have been
            // updated in a new app version). Preserve the same id so existing
            // CloudInstance.dockerImageId references still resolve.
            dockerImages[idx] = bundled
        } else {
            dockerImages.insert(bundled, at: 0)
        }
        saveDockerImages()
    }

    func addDockerImage(_ image: DockerImage) {
        dockerImages.append(image)
        saveDockerImages()
    }

    func updateDockerImage(_ image: DockerImage) {
        guard let idx = dockerImages.firstIndex(where: { $0.id == image.id }) else { return }
        dockerImages[idx] = image
        saveDockerImages()
    }

    func removeDockerImage(_ image: DockerImage) {
        guard !image.isBuiltIn else { return }
        dockerImages.removeAll { $0.id == image.id }
        // Unset any instance that pointed at this image.
        for i in cloudInstances.indices where cloudInstances[i].dockerImageId == image.id {
            cloudInstances[i].dockerImageId = nil
        }
        saveDockerImages()
        saveCloudInstances()
    }

    func duplicateDockerImage(_ image: DockerImage) -> DockerImage {
        let copy = DockerImage(
            name: "\(image.name) Copy",
            dockerfile: image.dockerfile,
            entrypoint: image.entrypoint,
            isBuiltIn: false
        )
        dockerImages.append(copy)
        saveDockerImages()
        return copy
    }

    /// Resolves the Docker image to use for an instance. Falls back to the
    /// bundled default if the instance's id is nil or no longer present.
    func dockerImage(for instance: CloudInstance) -> DockerImage {
        if let id = instance.dockerImageId,
           let img = dockerImages.first(where: { $0.id == id }) {
            return img
        }
        return dockerImages.first(where: { $0.id == DockerImageBuilder.bundledDefaultImageId })
            ?? DockerImageBuilder.bundledDefaultImage()
    }

    // MARK: - Modal Coordination (single-modal stack)

    /// Pauses the Create Instance sheet (saving the form draft) and opens the
    /// Docker image editor. When the editor closes, the form is restored.
    /// `image` = nil → create new; non-nil → edit existing.
    func pauseCloudInstanceSheetAndEditImage(draft: CloudInstanceDraft, image: DockerImage?) {
        cloudInstanceDraft = draft
        editingDockerImage = image
        showingAddCloudInstance = false
        showingDockerImageEditor = true
    }

    /// Closes the Docker image editor and resumes the Create Instance sheet
    /// with the previously saved draft.
    func closeImageEditorAndResumeCloudInstanceSheet() {
        showingDockerImageEditor = false
        editingDockerImage = nil
        // Re-open the Create Instance sheet; AddCloudInstanceSheet.onAppear
        // reads back cloudInstanceDraft if present.
        if cloudInstanceDraft != nil {
            showingAddCloudInstance = true
        }
    }

    /// Discards any pending draft. Called when the Create Instance sheet is
    /// dismissed via Cancel or successful creation.
    func clearCloudInstanceDraft() {
        cloudInstanceDraft = nil
    }

    /// Polls a single cloud instance status (used on selection for instant feedback).
    func pollSingleInstance(_ instance: CloudInstance) {
        switch instance.type {
        case .ssh:
            break
        case .ec2:
            guard let config = instance.ec2Config, !config.instanceId.isEmpty else { return }
            ec2Describe(instance) { [weak self] status, ip in
                guard let self else { return }
                var updated = self.cloudInstanceRuntimeInfo[instance.id] ?? CloudInstanceRuntimeInfo()
                updated.status = status
                updated.publicIP = ip
                if status == .running {
                    if updated.setupPhase != .ready { updated.setupPhase = .installingDocker }
                } else {
                    updated.setupPhase = .bootingHost
                }
                self.cloudInstanceRuntimeInfo[instance.id] = updated
                if status == .running, ip != nil {
                    self.probeEC2SetupPhase(for: instance)
                }
            }
        case .fargate:
            guard let config = instance.fargateConfig, !config.taskArn.isEmpty else { return }
            fargateDescribe(instance) { [weak self] status, ip in
                guard let self else { return }
                var updated = self.cloudInstanceRuntimeInfo[instance.id] ?? CloudInstanceRuntimeInfo()
                updated.status = status
                updated.publicIP = ip
                self.cloudInstanceRuntimeInfo[instance.id] = updated
            }
        case .docker:
            guard let config = instance.dockerConfig, !config.containerId.isEmpty else { return }
            dockerInspect(instance) { [weak self] status in
                guard let self else { return }
                var updated = self.cloudInstanceRuntimeInfo[instance.id] ?? CloudInstanceRuntimeInfo()
                updated.status = status
                self.cloudInstanceRuntimeInfo[instance.id] = updated
            }
        }
    }

    /// Tracks instances currently running the image-bootstrap step so we don't
    /// kick off `docker build` twice in parallel.
    private var imageBootstrapInProgress: Set<UUID> = []

    /// SSHes in to determine the current setup phase. If the host is ready but
    /// the image hasn't been built, kicks off the bootstrap. Safe to call repeatedly.
    func probeEC2SetupPhase(for instance: CloudInstance) {
        guard let target = resolveSSHTarget(for: instance) else { return }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            var sshArgs = ["-o", "ConnectTimeout=5",
                           "-o", "StrictHostKeyChecking=accept-new",
                           "-o", "UserKnownHostsFile=/dev/null",
                           "-o", "BatchMode=yes"]
            if !target.keyPath.isEmpty {
                sshArgs += ["-i", (target.keyPath as NSString).expandingTildeInPath]
            }
            if target.port != 22 { sshArgs += ["-p", "\(target.port)"] }
            sshArgs.append("\(target.user)@\(target.host)")
            // Probe: HOST_READY if cloud-init done, then docker container status.
            sshArgs.append("test -f ~/.claudehub-host-ready && echo HOST_READY; docker inspect -f '{{.State.Status}}' claudehub 2>/dev/null || true")

            let result = self.runCommand(
                executable: "/usr/bin/ssh",
                arguments: sshArgs,
                environment: ProcessInfo.processInfo.environment
            )

            let output = result.stdout
            let hostReady = output.contains("HOST_READY")
            let containerRunning = output.contains("running")
            let containerExists = output.contains("running") || output.contains("exited") || output.contains("created")

            DispatchQueue.main.async {
                var updated = self.cloudInstanceRuntimeInfo[instance.id] ?? CloudInstanceRuntimeInfo()
                let bootstrapping = self.imageBootstrapInProgress.contains(instance.id)

                // Reality wins: if the container is running, we're ready — clear any
                // stuck bootstrap flag and force the badge green. This prevents stale
                // in-memory state from keeping the UI on "Building image" forever.
                if containerRunning {
                    updated.setupPhase = .ready
                    self.imageBootstrapInProgress.remove(instance.id)
                } else if !result.success {
                    updated.setupPhase = .bootingHost
                } else if !hostReady {
                    updated.setupPhase = .installingDocker
                } else if bootstrapping {
                    updated.setupPhase = .buildingImage
                } else if !containerExists {
                    // Host is ready, no container yet, no bootstrap running → kick one off
                    updated.setupPhase = .buildingImage
                    self.cloudInstanceRuntimeInfo[instance.id] = updated
                    self.bootstrapEC2Image(instance)
                    return
                } else {
                    updated.setupPhase = .containerStarting
                }
                self.cloudInstanceRuntimeInfo[instance.id] = updated
            }
        }
    }

    /// Phase 2 of EC2 bootstrap: rsync the build context, build the image,
    /// run the container. Triggered automatically by `probeEC2SetupPhase` when
    /// the host is ready but no `claudehub` container exists yet.
    func bootstrapEC2Image(_ instance: CloudInstance) {
        guard !imageBootstrapInProgress.contains(instance.id) else { return }
        guard let target = resolveSSHTarget(for: instance) else { return }
        imageBootstrapInProgress.insert(instance.id)

        let image = dockerImage(for: instance)
        // Tag distinguishes per-image builds on the host so multiple instances
        // pointing at different images don't trample each other's docker tag.
        let imageTag = "claudehub:\(image.id.uuidString.prefix(8).lowercased())"

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            defer {
                DispatchQueue.main.async {
                    self.imageBootstrapInProgress.remove(instance.id)
                }
            }

            guard let buildContext = DockerImageBuilder.writeBuildContext(image: image) else {
                logger.warning("Failed to write build context for \(instance.name, privacy: .public)")
                return
            }
            defer { try? FileManager.default.removeItem(atPath: buildContext) }

            let userHost = target.user.isEmpty ? target.host : "\(target.user)@\(target.host)"
            let keyExpanded = (target.keyPath as NSString).expandingTildeInPath
            let sshOpts = "-o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=/dev/null"
                        + (target.port != 22 ? " -p \(target.port)" : "")
                        + (target.keyPath.isEmpty ? "" : " -i \(keyExpanded)")

            // 1. rsync build context to /opt/claudehub/
            let rsyncArgs = ["-az", "--delete",
                             "-e", "ssh \(sshOpts)",
                             "\(buildContext)/",
                             "\(userHost):/opt/claudehub/"]
            let rsyncResult = self.runCommand(executable: "/usr/bin/rsync", arguments: rsyncArgs, timeout: 120)
            guard rsyncResult.success else {
                logger.warning("Bootstrap rsync failed: \(rsyncResult.stderr, privacy: .public)")
                return
            }

            // 2. docker build + run remotely
            var buildSSHArgs = ["-o", "StrictHostKeyChecking=accept-new", "-o", "UserKnownHostsFile=/dev/null"]
            if target.port != 22 { buildSSHArgs += ["-p", "\(target.port)"] }
            if !target.keyPath.isEmpty { buildSSHArgs += ["-i", keyExpanded] }
            buildSSHArgs.append(userHost)
            buildSSHArgs.append("""
                set -e
                chmod +x /opt/claudehub/entrypoint.sh
                cd /opt/claudehub
                docker build -t \(imageTag) .
                docker rm -f claudehub 2>/dev/null || true
                docker run -d --name claudehub \
                    --restart unless-stopped \
                    --cap-add=SYS_ADMIN \
                    --shm-size=2g \
                    -p 5900:5900 \
                    -p 6080:6080 \
                    -p 2222:22 \
                    -v /home/ubuntu/projects:/workspace \
                    -v /home/ubuntu/.ssh/authorized_keys:/root/.ssh/authorized_keys:ro \
                    \(imageTag)
                """)

            let buildResult = self.runCommand(executable: "/usr/bin/ssh", arguments: buildSSHArgs, timeout: 900)
            if buildResult.success {
                logger.info("Image bootstrap complete for \(instance.name, privacy: .public)")
            } else {
                logger.warning("Image bootstrap failed: \(buildResult.stderr, privacy: .public)")
            }
        }
    }

    func pairProject(_ projectId: String, with instanceId: UUID) {
        guard let index = cloudInstances.firstIndex(where: { $0.id == instanceId }) else { return }
        if !cloudInstances[index].pairedProjectIds.contains(projectId) {
            cloudInstances[index].pairedProjectIds.append(projectId)
            saveCloudInstances()
            if selectedCloudInstance?.id == instanceId {
                selectedCloudInstance = cloudInstances[index]
            }
        }
    }

    func unpairProject(_ projectId: String, from instanceId: UUID) {
        guard let index = cloudInstances.firstIndex(where: { $0.id == instanceId }) else { return }
        cloudInstances[index].pairedProjectIds.removeAll { $0 == projectId }
        saveCloudInstances()
        if selectedCloudInstance?.id == instanceId {
            selectedCloudInstance = cloudInstances[index]
        }
    }

    // MARK: - Server Configuration

    func loadServers(for project: Project) {
        let mcpPath = "\(project.path)/\(Config.mcpConfigPath)"
        let gatewayPath = "\(project.path)/\(Config.gatewayConfigPath)"

        guard let mcpData = try? Data(contentsOf: URL(fileURLWithPath: mcpPath)),
              let mcpConfig = try? JSONDecoder().decode(MCPConfig.self, from: mcpData) else {
            servers = []
            return
        }

        let existingGateway = loadGatewayConfig(path: gatewayPath)

        servers = mcpConfig.mcpServers.map { (name, config) in
            let command = config.command ?? ""
            let args = config.args ?? []
            let env = config.env ?? [:]

            let existing = existingGateway?.servers[name]
            let enabled = existing?.enabled ?? true

            let enabledToolNames: Set<String>?
            if let cfg = existing {
                switch cfg.tools {
                case .all: enabledToolNames = nil
                case .specific(let names): enabledToolNames = Set(names)
                }
            } else {
                enabledToolNames = nil
            }

            let allToolNames = existing?.discoveredTools ?? []
            let tools: [DiscoveredTool] = allToolNames.map { toolName in
                let isEnabled = enabledToolNames.map { $0.contains(toolName) } ?? true
                return DiscoveredTool(name: toolName, description: "", enabled: isEnabled)
            }

            return ServerState(
                name: name,
                enabled: enabled,
                tools: tools,
                command: command,
                args: args,
                env: env,
                serverType: config.type,
                url: config.url,
                headersHelper: config.headersHelper
            )
        }.sorted { $0.name < $1.name }
    }

    private func loadGatewayConfig(path: String) -> GatewayConfig? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else { return nil }
        return try? JSONDecoder().decode(GatewayConfig.self, from: data)
    }

    // MARK: - Server CRUD

    /// Adds a new MCP server to the current project's .mcp.json.
    /// Routes the command through run-mcp.sh so .env secrets are injected.
    func addServer(name: String, config: MCPServerConfig) {
        guard let project = selectedProject else { return }
        let mcpPath = "\(project.path)/\(Config.mcpConfigPath)"

        // Ensure run-mcp.sh exists (for projects added before this feature)
        let runMcpPath = "\(project.path)/.claude/infra/scripts/run-mcp.sh"
        if !FileManager.default.fileExists(atPath: runMcpPath) {
            scaffoldClaudeStructure(at: project.path)
        }

        var existing: [String: Any] = [:]
        if let data = try? Data(contentsOf: URL(fileURLWithPath: mcpPath)),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            existing = json
        }

        var mcpServers = existing["mcpServers"] as? [String: Any] ?? [:]

        var serverDict: [String: Any] = [:]

        // Route through run-mcp.sh: the original command + args become
        // args to the wrapper, so .env secrets get sourced before exec.
        if let command = config.command {
            serverDict["command"] = "./.claude/infra/scripts/run-mcp.sh"
            var wrapperArgs = [command]
            if let args = config.args { wrapperArgs.append(contentsOf: args) }
            serverDict["args"] = wrapperArgs
        }
        if let env = config.env, !env.isEmpty { serverDict["env"] = env }

        mcpServers[name] = serverDict
        existing["mcpServers"] = mcpServers

        if let data = try? JSONSerialization.data(withJSONObject: existing, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) {
            try? data.write(to: URL(fileURLWithPath: mcpPath))
        }

        loadServers(for: project)
    }

    /// Removes an MCP server from the current project's .mcp.json and gateway config.
    func removeServer(name: String) {
        guard let project = selectedProject else { return }
        let mcpPath = "\(project.path)/\(Config.mcpConfigPath)"
        let gatewayConfigPath = "\(project.path)/\(Config.gatewayConfigPath)"

        // Remove from .mcp.json
        if let data = try? Data(contentsOf: URL(fileURLWithPath: mcpPath)),
           var json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           var mcpServers = json["mcpServers"] as? [String: Any] {
            mcpServers.removeValue(forKey: name)
            json["mcpServers"] = mcpServers
            if let newData = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) {
                try? newData.write(to: URL(fileURLWithPath: mcpPath))
            }
        }

        // Remove from gateway.config.json
        if let data = try? Data(contentsOf: URL(fileURLWithPath: gatewayConfigPath)),
           var json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           var servers = json["servers"] as? [String: Any] {
            servers.removeValue(forKey: name)
            json["servers"] = servers
            if let newData = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) {
                try? newData.write(to: URL(fileURLWithPath: gatewayConfigPath))
            }
        }

        loadServers(for: project)
    }

    // MARK: - MCP Registry Search

    /// Searches the MCP registry for servers matching the query.
    func searchRegistry(query: String, registryURL: String? = nil, completion: @escaping (Result<[RegistryServer], Error>) -> Void) {
        let baseURL = registryURL ?? settings.registryURLs.first ?? "https://registry.modelcontextprotocol.io/v0.1/servers"
        guard var components = URLComponents(string: baseURL) else {
            completion(.failure(URLError(.badURL)))
            return
        }
        var queryItems = components.queryItems ?? []
        if !query.isEmpty {
            queryItems.append(URLQueryItem(name: "search", value: query))
        }
        queryItems.append(URLQueryItem(name: "limit", value: "20"))
        components.queryItems = queryItems

        guard let url = components.url else {
            completion(.failure(URLError(.badURL)))
            return
        }

        URLSession.shared.dataTask(with: url) { data, _, error in
            if let error {
                DispatchQueue.main.async { completion(.failure(error)) }
                return
            }
            guard let data else {
                DispatchQueue.main.async { completion(.failure(URLError(.zeroByteResource))) }
                return
            }
            do {
                let response = try JSONDecoder().decode(RegistrySearchResponse.self, from: data)
                DispatchQueue.main.async { completion(.success(response.servers ?? [])) }
            } catch {
                DispatchQueue.main.async { completion(.failure(error)) }
            }
        }.resume()
    }

    // MARK: - Tool Discovery

    func discoverTools() {
        guard let project = selectedProject else {
            logger.warning("discoverTools: no selectedProject")
            return
        }
        logger.info("discoverTools: starting for \(project.name) with \(self.servers.count) servers")
        isDiscovering = true

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }

            for server in self.servers {
                guard server.enabled else {
                    logger.info("discoverTools: skipping disabled server \(server.name)")
                    continue
                }
                if server.isHTTP {
                    logger.info("discoverTools: skipping \(server.name) (HTTP, no stdio discovery)")
                    continue
                }

                logger.info("discoverTools: discovering tools for \(server.name)")
                let tools = self.discoverToolsForServer(server, projectPath: project.path)
                logger.info("discoverTools: \(server.name) returned \(tools.count) tools")
                DispatchQueue.main.async {
                    let existingEnabled = Set(server.tools.filter(\.enabled).map(\.name))
                    server.tools = tools.map { tool in
                        var t = tool
                        if !existingEnabled.isEmpty {
                            t.enabled = existingEnabled.contains(t.name)
                        }
                        return t
                    }
                }
            }

            DispatchQueue.main.async {
                self.isDiscovering = false
                self.saveConfig()
            }
        }
    }

    private func discoverToolsForServer(_ server: ServerState, projectPath: String) -> [DiscoveredTool] {
        let command = resolveCommand(server.command, projectPath: projectPath)
        logger.info("discoverToolsForServer: \(server.name) command=\(command) args=\(server.args)")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: command)
        process.arguments = server.args
        process.currentDirectoryURL = URL(fileURLWithPath: projectPath)

        var env = ProcessInfo.processInfo.environment
        env["PATH"] = Self.userShellPATH
        for (k, v) in server.env { env[k] = v }
        loadEnvFile(into: &env, projectPath: projectPath)
        process.environment = env

        let stdin = Pipe()
        let stdout = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = Pipe()

        let jsonrpc = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"protocolVersion\":\"2024-11-05\",\"capabilities\":{},\"clientInfo\":{\"name\":\"claude-hub\",\"version\":\"1.0.0\"}}}\n{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}\n{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/list\",\"params\":{}}\n"

        do {
            try process.run()
            logger.info("discoverToolsForServer: \(server.name) process started, sending JSON-RPC")

            stdin.fileHandleForWriting.write(jsonrpc.data(using: .utf8)!)
            stdin.fileHandleForWriting.closeFile()

            var stdoutData = Data()
            let readGroup = DispatchGroup()
            readGroup.enter()
            DispatchQueue.global(qos: .utility).async {
                stdoutData = stdout.fileHandleForReading.readDataToEndOfFile()
                readGroup.leave()
            }

            let timer = DispatchSource.makeTimerSource()
            timer.schedule(deadline: .now() + Config.toolDiscoveryTimeout)
            timer.setEventHandler {
                logger.warning("discoverToolsForServer: \(server.name) TIMEOUT, terminating")
                process.terminate()
            }
            timer.resume()

            process.waitUntilExit()
            timer.cancel()
            logger.info("discoverToolsForServer: \(server.name) process exited with status \(process.terminationStatus)")

            readGroup.wait()

            let output = String(data: stdoutData, encoding: .utf8) ?? ""
            logger.info("discoverToolsForServer: \(server.name) output length=\(output.count)")
            let tools = parseToolsFromOutput(output)
            logger.info("discoverToolsForServer: \(server.name) parsed \(tools.count) tools")
            return tools
        } catch {
            logger.error("discoverToolsForServer: \(server.name) failed to start: \(error.localizedDescription)")
            return []
        }
    }

    /// The user's full shell PATH, resolved once by sourcing their login shell profile.
    private static let userShellPATH: String = {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = ["-ilc", "echo $PATH"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let path = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !path.isEmpty {
                logger.info("resolveCommand: resolved user PATH (\(path.components(separatedBy: ":").count) entries)")
                return path
            }
        } catch {}
        return ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin"
    }()

    private func resolveCommand(_ command: String, projectPath: String) -> String {
        if command.hasPrefix("./") {
            return "\(projectPath)/\(command.dropFirst(2))"
        }
        if command.hasPrefix("/") {
            return command
        }
        // Use the user's full shell PATH to find commands (GUI apps have a minimal PATH)
        let which = Process()
        which.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        which.arguments = ["which", command]
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = Self.userShellPATH
        which.environment = env
        let pipe = Pipe()
        which.standardOutput = pipe
        which.standardError = Pipe()
        do {
            try which.run()
            which.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let resolved = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !resolved.isEmpty {
                return resolved
            }
        } catch {}
        logger.warning("resolveCommand: could not resolve '\(command)' in user PATH")
        return command
    }

    private func loadEnvFile(into env: inout [String: String], projectPath: String) {
        let envPath = "\(projectPath)/\(Config.envFilePath)"
        guard let content = try? String(contentsOfFile: envPath, encoding: .utf8) else { return }

        for line in content.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { continue }
            let parts = trimmed.split(separator: "=", maxSplits: 1)
            if parts.count == 2 {
                env[String(parts[0])] = String(parts[1])
            }
        }
    }

    private func parseToolsFromOutput(_ output: String) -> [DiscoveredTool] {
        let lines = output.components(separatedBy: .newlines)
        for line in lines {
            guard let data = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let result = json["result"] as? [String: Any],
                  let tools = result["tools"] as? [[String: Any]] else {
                continue
            }

            return tools.compactMap { tool in
                guard let name = tool["name"] as? String else { return nil }
                let desc = tool["description"] as? String ?? ""
                return DiscoveredTool(name: name, description: desc, enabled: true)
            }
        }
        return []
    }

    // MARK: - Config Persistence

    func saveConfig() {
        guard let project = selectedProject else { return }
        let projectPath = project.path.hasSuffix("/") ? String(project.path.dropLast()) : project.path
        let gatewayConfigPath = "\(projectPath)/\(Config.gatewayConfigPath)"
        let mcpJsonPath = "\(projectPath)/.mcp.json"

        var gatewayServers: [String: GatewayServerConfig] = [:]

        for server in servers where !server.isHTTP {
            let command = resolveCommand(server.command, projectPath: projectPath)
            let toolsFilter: GatewayServerConfig.ToolsFilter

            if server.tools.isEmpty || server.tools.allSatisfy(\.enabled) {
                toolsFilter = .all
            } else {
                toolsFilter = .specific(server.tools.filter(\.enabled).map(\.name))
            }

            let allToolNames = server.tools.isEmpty ? nil : server.tools.map(\.name)

            gatewayServers[server.name] = GatewayServerConfig(
                enabled: server.enabled,
                command: command,
                args: server.args,
                env: server.env.isEmpty ? nil : server.env,
                tools: toolsFilter,
                discoveredTools: allToolNames
            )
        }

        let gatewayConfig = GatewayConfig(servers: gatewayServers)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]

        if let data = try? encoder.encode(gatewayConfig) {
            try? data.write(to: URL(fileURLWithPath: gatewayConfigPath))
        }

        // One gateway entry per enabled stdio server, HTTP servers go direct
        let nodeCommand = resolveCommand("node", projectPath: projectPath)
        var mcpServerEntries: [String: Any] = [:]
        for server in servers where server.enabled {
            if server.isHTTP {
                // HTTP servers bypass the gateway
                var entry: [String: Any] = [
                    "type": server.serverType!,
                    "url": server.url!
                ]
                if let helper = server.headersHelper {
                    entry["headersHelper"] = helper
                }
                mcpServerEntries[server.name] = entry
            } else {
                mcpServerEntries[server.name] = [
                    "command": nodeCommand,
                    "args": ["\(gatewayPath)/index.js"],
                    "env": [
                        "MCP_GATEWAY_CONFIG": gatewayConfigPath,
                        "MCP_GATEWAY_SERVER": server.name
                    ]
                ] as [String: Any]
            }
        }
        let mcpJson: [String: Any] = ["mcpServers": mcpServerEntries]

        if let data = try? JSONSerialization.data(withJSONObject: mcpJson, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) {
            try? FileManager.default.removeItem(atPath: mcpJsonPath)
            try? data.write(to: URL(fileURLWithPath: mcpJsonPath))
        }

        // Sync to Claude Desktop's config
        writeDesktopConfig(for: project)
    }

    // MARK: - Claude Desktop Config Sync

    /// Writes enabled MCP servers to claude_desktop_config.json in the project's
    /// isolated user-data-dir, preserving existing preferences and other keys.
    private func writeDesktopConfig(for project: Project) {
        let settingsDir = claudeSettingsDir(for: project)
        let configPath = "\(settingsDir)/claude_desktop_config.json"
        let projectPath = project.path.hasSuffix("/") ? String(project.path.dropLast()) : project.path
        let gatewayConfigPath = "\(projectPath)/\(Config.gatewayConfigPath)"
        let nodeCommand = resolveCommand("node", projectPath: projectPath)

        // Read existing file to preserve preferences and other keys
        var existing: [String: Any] = [:]
        if let data = try? Data(contentsOf: URL(fileURLWithPath: configPath)),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            existing = json
        }

        // Build mcpServers dict with enabled servers only
        var mcpServers: [String: Any] = [:]

        // Preserve any non-gateway servers already in the file
        if let currentServers = existing["mcpServers"] as? [String: Any] {
            for (name, config) in currentServers {
                if let serverDict = config as? [String: Any],
                   let env = serverDict["env"] as? [String: String],
                   env["MCP_GATEWAY_SERVER"] != nil {
                    // Gateway-managed — will be rebuilt below
                    continue
                }
                // Non-gateway server — preserve it
                mcpServers[name] = config
            }
        }

        // Add enabled gateway servers
        for server in servers where server.enabled {
            mcpServers[server.name] = [
                "command": nodeCommand,
                "args": ["\(gatewayPath)/index.js"],
                "env": [
                    "MCP_GATEWAY_CONFIG": gatewayConfigPath,
                    "MCP_GATEWAY_SERVER": server.name
                ]
            ] as [String: Any]
        }

        existing["mcpServers"] = mcpServers

        // Write back
        try? FileManager.default.createDirectory(
            atPath: settingsDir,
            withIntermediateDirectories: true
        )

        if let data = try? JSONSerialization.data(
            withJSONObject: existing,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        ) {
            try? data.write(to: URL(fileURLWithPath: configPath))
        }

        // Record our write timestamp to avoid treating it as an external change
        if let attrs = try? FileManager.default.attributesOfItem(atPath: configPath),
           let modDate = attrs[.modificationDate] as? Date {
            lastDesktopConfigWriteDate = modDate
        }

        // Enable all disabled tools in session files. The gateway handles
        // per-tool filtering, so we just need everything enabled at the
        // Claude Desktop level to avoid "disabled in connector settings".
        enableAllToolsInSessions(settingsDir: settingsDir)
    }

    /// Sets all disabled MCP tools to enabled in Claude Desktop session files.
    /// The gateway's tool filter handles which tools are actually exposed.
    private func enableAllToolsInSessions(settingsDir: String) {
        let sessionsBase = "\(settingsDir)/claude-code-sessions"
        guard let orgDirs = try? FileManager.default.contentsOfDirectory(atPath: sessionsBase) else { return }

        for orgDir in orgDirs {
            let orgPath = "\(sessionsBase)/\(orgDir)"
            guard let accountDirs = try? FileManager.default.contentsOfDirectory(atPath: orgPath) else { continue }
            for accountDir in accountDirs {
                let accountPath = "\(orgPath)/\(accountDir)"
                guard let files = try? FileManager.default.contentsOfDirectory(atPath: accountPath) else { continue }
                for file in files where file.hasPrefix("local_") && file.hasSuffix(".json") {
                    let filePath = "\(accountPath)/\(file)"
                    guard let data = try? Data(contentsOf: URL(fileURLWithPath: filePath)),
                          var json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                          var tools = json["enabledMcpTools"] as? [String: Bool] else { continue }

                    var changed = false
                    for (toolName, enabled) in tools where !enabled {
                        tools[toolName] = true
                        changed = true
                    }

                    if changed {
                        json["enabledMcpTools"] = tools
                        if let newData = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) {
                            try? newData.write(to: URL(fileURLWithPath: filePath))
                        }
                    }
                }
            }
        }
    }

    /// Detects external changes to claude_desktop_config.json (e.g. user toggling
    /// servers in Claude Desktop UI) and syncs them back to gateway.config.json.
    private func syncFromDesktopConfig(for project: Project) {
        let settingsDir = claudeSettingsDir(for: project)
        let configPath = "\(settingsDir)/claude_desktop_config.json"
        let projectPath = project.path.hasSuffix("/") ? String(project.path.dropLast()) : project.path
        let gatewayConfigPath = "\(projectPath)/\(Config.gatewayConfigPath)"

        // Check if file exists
        guard FileManager.default.fileExists(atPath: configPath) else { return }

        // Check modification date — skip if this is our own write
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: configPath),
              let modDate = attrs[.modificationDate] as? Date else { return }

        if let lastWrite = lastDesktopConfigWriteDate, modDate == lastWrite {
            return // No external changes
        }

        // Read desktop config
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: configPath)),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }

        let desktopServers = json["mcpServers"] as? [String: Any] ?? [:]

        // Extract gateway-managed server names from desktop config
        var desktopGatewayServerNames: Set<String> = []
        for (_, config) in desktopServers {
            if let serverDict = config as? [String: Any],
               let env = serverDict["env"] as? [String: String],
               let serverName = env["MCP_GATEWAY_SERVER"] {
                desktopGatewayServerNames.insert(serverName)
            }
        }

        // Read current gateway config
        guard var gatewayConfig = loadGatewayConfig(path: gatewayConfigPath) else { return }

        var changed = false

        for (name, var serverConfig) in gatewayConfig.servers {
            let isInDesktop = desktopGatewayServerNames.contains(name)

            if serverConfig.enabled && !isInDesktop {
                // Server was enabled in gateway but removed from desktop config
                // → user disabled it in Claude Desktop
                serverConfig.enabled = false
                gatewayConfig.servers[name] = serverConfig
                changed = true
                logger.info("syncFromDesktopConfig: disabled \(name) (removed from Claude Desktop)")
            } else if !serverConfig.enabled && isInDesktop {
                // Server was disabled in gateway but present in desktop config
                // → user re-enabled it in Claude Desktop
                serverConfig.enabled = true
                gatewayConfig.servers[name] = serverConfig
                changed = true
                logger.info("syncFromDesktopConfig: enabled \(name) (added in Claude Desktop)")
            }
        }

        if changed {
            // Write only gateway config (NOT desktop config to avoid loops)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            if let data = try? encoder.encode(gatewayConfig) {
                try? data.write(to: URL(fileURLWithPath: gatewayConfigPath))
            }

            // Reload UI
            DispatchQueue.main.async {
                self.loadServers(for: project)
            }
        }

        // Update tracking timestamp
        lastDesktopConfigWriteDate = modDate
    }

    // MARK: - Claude Desktop Lifecycle (Global — isolation OFF)

    func applyAndRestart() {
        guard !isRestarting else { return }
        saveConfig()
        isRestarting = true

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }

            self.terminateClaude()
            Thread.sleep(forTimeInterval: 2.0)
            self.launchClaudeViaFinder()

            DispatchQueue.main.async {
                self.isClaudeRunning = self.findClaudeApp() != nil
                self.isRestarting = false
            }
        }
    }

    func startClaude() {
        guard !isRestarting else { return }
        saveConfig()
        isRestarting = true

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            self.launchClaudeViaFinder()

            DispatchQueue.main.async {
                self.isClaudeRunning = self.findClaudeApp() != nil
                self.isRestarting = false
            }
        }
    }

    private func terminateClaude() {
        guard let app = findClaudeApp() else { return }

        app.terminate()
        for _ in 0..<Config.gracefulTerminationAttempts {
            Thread.sleep(forTimeInterval: Config.pollStep)
            if findClaudeApp() == nil { return }
        }

        app.forceTerminate()
        for _ in 0..<Config.forceTerminationAttempts {
            Thread.sleep(forTimeInterval: Config.pollStep)
            if findClaudeApp() == nil { return }
        }
    }

    private func launchClaudeViaFinder() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = [
            "-e",
            "tell application \"Finder\" to open POSIX file \"/Applications/Claude.app\""
        ]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try? process.run()
        process.waitUntilExit()

        for _ in 0..<Config.launchPollAttempts {
            Thread.sleep(forTimeInterval: Config.pollStep)
            if findClaudeApp() != nil { break }
        }

        Thread.sleep(forTimeInterval: Config.processSettleDelay)
    }

    private func findClaudeApp() -> NSRunningApplication? {
        NSWorkspace.shared.runningApplications.first {
            $0.bundleIdentifier == Config.claudeBundleId
        }
    }

    // MARK: - Claude Desktop Lifecycle (Per-Project — isolation ON)

    /// Returns the settings directory for a project: ~/claude-{name}
    func claudeSettingsDir(for project: Project) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let safeName = project.name
            .lowercased()
            .replacingOccurrences(of: " ", with: "-")
        return "\(home)/claude-\(safeName)"
    }

    /// Launches a new Claude Desktop instance for the given project.
    func launchClaudeForProject(_ project: Project) {
        let info = projectInstances[project.id] ?? ProjectInstanceInfo()
        guard !info.isRestarting else { return }

        if info.isRunning {
            restartClaudeForProject(project)
            return
        }

        if project.id == selectedProject?.id {
            saveConfig()
        }

        // Track that a launch is in progress to prevent double-clicks.
        logger.info("launchClaudeForProject: starting for \(project.name)")
        projectInstances[project.id] = ProjectInstanceInfo(isRestarting: true, restartingSince: Date())

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else {
                logger.warning("launchClaudeForProject: self deallocated")
                return
            }

            logger.info("launchClaudeForProject: calling doLaunchClaude")
            let pid = self.doLaunchClaude(for: project)
            logger.info("launchClaudeForProject: doLaunchClaude returned pid=\(pid.map { String($0) } ?? "nil")")

            DispatchQueue.main.async {
                logger.info("launchClaudeForProject: clearing isRestarting on main thread")
                self.projectInstances[project.id] = ProjectInstanceInfo(
                    isRunning: false,
                    isRestarting: false,
                    pid: pid
                )
            }

            guard let pid else { return }

            // Poll in the background to confirm it's running
            var finalPid = pid
            for _ in 0..<Config.launchPollAttempts {
                Thread.sleep(forTimeInterval: Config.pollStep)
                if kill(finalPid, 0) == 0 { break }
                let settingsDir = self.claudeSettingsDir(for: project)
                if let newPid = self.findClaudePid(settingsDir: settingsDir) {
                    finalPid = newPid
                    break
                }
            }
            Thread.sleep(forTimeInterval: Config.processSettleDelay)
            let running = kill(finalPid, 0) == 0
            DispatchQueue.main.async {
                self.projectInstances[project.id] = ProjectInstanceInfo(
                    isRunning: running,
                    isRestarting: false,
                    pid: running ? finalPid : nil
                )
            }
        }
    }

    /// Restarts the Claude Desktop instance for the given project.
    func restartClaudeForProject(_ project: Project) {
        let info = projectInstances[project.id] ?? ProjectInstanceInfo()
        guard !info.isRestarting else { return }

        if project.id == selectedProject?.id {
            saveConfig()
        }

        projectInstances[project.id] = ProjectInstanceInfo(
            isRunning: info.isRunning,
            isRestarting: true,
            restartingSince: Date(),
            pid: info.pid
        )

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }

            if let pid = info.pid {
                self.doTerminateClaude(pid: pid)
            }

            Thread.sleep(forTimeInterval: 2.0)

            let pid = self.doLaunchClaude(for: project)

            // Clear the spinner immediately
            DispatchQueue.main.async {
                self.projectInstances[project.id] = ProjectInstanceInfo(
                    isRunning: false,
                    isRestarting: false,
                    pid: pid
                )
            }

            guard let pid else { return }

            var finalPid = pid
            for _ in 0..<Config.launchPollAttempts {
                Thread.sleep(forTimeInterval: Config.pollStep)
                if kill(finalPid, 0) == 0 { break }
                let settingsDir = self.claudeSettingsDir(for: project)
                if let newPid = self.findClaudePid(settingsDir: settingsDir) {
                    finalPid = newPid
                    break
                }
            }
            Thread.sleep(forTimeInterval: Config.processSettleDelay)
            let running = kill(finalPid, 0) == 0
            DispatchQueue.main.async {
                self.projectInstances[project.id] = ProjectInstanceInfo(
                    isRunning: running,
                    isRestarting: false,
                    pid: running ? finalPid : nil
                )
            }
        }
    }

    /// Launches a Claude Desktop instance isolated to the project's settings directory.
    /// Creates a lightweight wrapper .app so the Dock shows a custom name.
    private func doLaunchClaude(for project: Project) -> Int32? {
        let settingsDir = claudeSettingsDir(for: project)
        logger.info("doLaunchClaude: settingsDir=\(settingsDir)")
        logger.info("doLaunchClaude: building wrapper app")
        let wrapperApp = buildWrapperApp(for: project, settingsDir: settingsDir)
        logger.info("doLaunchClaude: wrapperApp=\(wrapperApp)")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-a", wrapperApp]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            logger.info("doLaunchClaude: open started, waiting for exit")
            process.waitUntilExit()
            logger.info("doLaunchClaude: open exited with status \(process.terminationStatus)")

            Thread.sleep(forTimeInterval: 2.0)
            let pid = findClaudePid(settingsDir: settingsDir)
            logger.info("doLaunchClaude: findClaudePid returned \(pid.map { String($0) } ?? "nil")")
            return pid
        } catch {
            logger.error("doLaunchClaude: failed to run open: \(error.localizedDescription)")
            return nil
        }
    }

    /// Finds the PID of a Claude process running with the given --user-data-dir.
    private func findClaudePid(settingsDir: String) -> Int32? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-eo", "pid,args"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()

            // Read pipe data concurrently to avoid deadlock when output exceeds pipe buffer
            var data = Data()
            let readGroup = DispatchGroup()
            readGroup.enter()
            DispatchQueue.global(qos: .utility).async {
                data = pipe.fileHandleForReading.readDataToEndOfFile()
                readGroup.leave()
            }

            process.waitUntilExit()
            readGroup.wait()

            let output = String(data: data, encoding: .utf8) ?? ""

            // Match the main Claude process (--user-data-dir) or its crashpad handler
            // (--database=settingsDir/Crashpad). Prefer the main process.
            var mainPid: Int32?
            var crashpadPid: Int32?
            for line in output.components(separatedBy: .newlines) {
                guard line.contains("Claude"), line.contains(settingsDir) else { continue }
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard let pidStr = trimmed.split(separator: " ").first,
                      let pid = Int32(pidStr) else { continue }
                if line.contains("--user-data-dir=\(settingsDir)") {
                    mainPid = pid
                    break
                }
                if crashpadPid == nil, line.contains("--database=\(settingsDir)") {
                    crashpadPid = pid
                }
            }
            if let pid = mainPid ?? crashpadPid { return pid }
        } catch {}
        return nil
    }

    // MARK: - Wrapper App Generation

    /// Directory where wrapper .app bundles are stored.
    private static var wrappersDir: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return "\(home)/Applications/Claude Hub Wrappers"
    }

    /// Builds (or updates) a lightweight .app wrapper that launches Claude with
    /// --user-data-dir and shows a custom name in the Dock.
    private func buildWrapperApp(for project: Project, settingsDir: String) -> String {
        logger.info("buildWrapperApp: START for \(project.name)")
        let displayName = settings.isolationDisplayName(for: project.name)
        let appDir = "\(Self.wrappersDir)/\(displayName).app"
        let contentsDir = "\(appDir)/Contents"
        let macosDir = "\(contentsDir)/MacOS"
        let resourcesDir = "\(contentsDir)/Resources"
        let fm = FileManager.default

        try? fm.createDirectory(atPath: macosDir, withIntermediateDirectories: true)
        try? fm.createDirectory(atPath: resourcesDir, withIntermediateDirectories: true)

        // --- Info.plist ---
        let bundleId = "com.claudehub.wrapper.\(project.name.lowercased().replacingOccurrences(of: " ", with: "-"))"
        let plist: [String: Any] = [
            "CFBundleName": displayName,
            "CFBundleDisplayName": displayName,
            "CFBundleIdentifier": bundleId,
            "CFBundleExecutable": "Claude",
            "CFBundleIconFile": "AppIcon",
            "CFBundlePackageType": "APPL",
            "CFBundleVersion": "\(Int(Date().timeIntervalSince1970))",
            "CFBundleShortVersionString": "1.0",
            "LSUIElement": false,
        ]
        let plistPath = "\(contentsDir)/Info.plist"
        (plist as NSDictionary).write(toFile: plistPath, atomically: true)

        // --- Tiny compiled launcher that exec's Claude with --user-data-dir ---
        // We compile a small C program that calls execv() on the real Claude binary.
        // Unlike a bash script, this exec's instantly and the resulting process inherits
        // Claude.app's code signature (macOS validates the binary loaded into memory,
        // not the original file). Unlike symlinks, this lets us bake in the argument.
        let claudeApp = "/Applications/Claude.app"
        let claudeContents = "\(claudeApp)/Contents"
        let claudePath = Bundle(path: claudeApp)?.executablePath
            ?? "\(claudeContents)/MacOS/Claude"

        let launcherSrc = """
        #include <unistd.h>
        int main(int argc, char *argv[]) {
            char *args[] = {"\(claudePath)", "--user-data-dir=\(settingsDir)", 0};
            return execv("\(claudePath)", args);
        }
        """
        let srcPath = "\(macosDir)/launcher.c"
        let binPath = "\(macosDir)/Claude"
        try? fm.removeItem(atPath: "\(macosDir)/launch") // cleanup old bash launcher
        try? launcherSrc.write(toFile: srcPath, atomically: true, encoding: .utf8)

        // Compile the tiny launcher (only if source changed or binary missing)
        let needsCompile: Bool
        if fm.fileExists(atPath: binPath),
           let srcDate = (try? fm.attributesOfItem(atPath: srcPath))?[.modificationDate] as? Date,
           let binDate = (try? fm.attributesOfItem(atPath: binPath))?[.modificationDate] as? Date,
           binDate > srcDate {
            needsCompile = false
        } else {
            needsCompile = true
        }
        logger.info("buildWrapperApp: needsCompile=\(needsCompile)")
        if needsCompile {
            try? fm.removeItem(atPath: binPath)
            let cc = Process()
            cc.executableURL = URL(fileURLWithPath: "/usr/bin/cc")
            cc.arguments = ["-O2", "-o", binPath, srcPath]
            cc.standardOutput = FileHandle.nullDevice
            cc.standardError = FileHandle.nullDevice
            if (try? cc.run()) != nil {
                cc.waitUntilExit()
                logger.info("buildWrapperApp: cc exited with status \(cc.terminationStatus)")
            } else {
                logger.error("buildWrapperApp: cc failed to start")
            }
        }
        // Keep source file so needsCompile check works on next launch

        // --- Generate icon (with optional badge) ---
        logger.info("buildWrapperApp: generating icon")
        let iconDest = "\(resourcesDir)/AppIcon.icns"
        try? fm.removeItem(atPath: iconDest)
        do {
            try IconCompositor.generateIcon(
                badge: project.badgeIcon,
                outputPath: iconDest,
                badgeImageLoader: { self.loadBadgeImage(filename: $0) }
            )
            logger.info("buildWrapperApp: icon generated OK")
        } catch {
            logger.error("buildWrapperApp: icon generation failed: \(error.localizedDescription)")
            let claudeIconCandidates = [
                "\(claudeContents)/Resources/AppIcon.icns",
                "\(claudeContents)/Resources/icon.icns",
                "\(claudeContents)/Resources/electron.icns",
            ]
            for candidate in claudeIconCandidates {
                if fm.fileExists(atPath: candidate) {
                    try? fm.copyItem(atPath: candidate, toPath: iconDest)
                    break
                }
            }
        }

        logger.info("buildWrapperApp: DONE, returning \(appDir)")
        return appDir
    }

    /// Cleans up old wrapper apps that no longer match the current naming settings.
    func cleanupStaleWrappers() {
        let fm = FileManager.default
        guard fm.fileExists(atPath: Self.wrappersDir) else { return }

        // Build set of expected wrapper names
        let expectedNames = Set(projects.map { settings.isolationDisplayName(for: $0.name) })

        guard let contents = try? fm.contentsOfDirectory(atPath: Self.wrappersDir) else { return }
        for item in contents where item.hasSuffix(".app") {
            let name = String(item.dropLast(4)) // remove .app
            if !expectedNames.contains(name) {
                try? fm.removeItem(atPath: "\(Self.wrappersDir)/\(item)")
            }
        }
    }

    /// Terminates a Claude process by PID (graceful then forced).
    private func doTerminateClaude(pid: Int32) {
        kill(pid, SIGTERM)
        for _ in 0..<Config.gracefulTerminationAttempts {
            Thread.sleep(forTimeInterval: Config.pollStep)
            if kill(pid, 0) != 0 { return }
        }
        kill(pid, SIGKILL)
        for _ in 0..<Config.forceTerminationAttempts {
            Thread.sleep(forTimeInterval: Config.pollStep)
            if kill(pid, 0) != 0 { return }
        }
    }

    // MARK: - Cloud Instance Operations

    /// Resolves the full path for a CLI tool (aws, docker, etc.).
    static func resolveExecutable(_ name: String) -> String {
        let candidates = [
            "/opt/homebrew/bin/\(name)",
            "/usr/local/bin/\(name)",
            "/usr/bin/\(name)",
        ]
        for path in candidates {
            if FileManager.default.fileExists(atPath: path) {
                return path
            }
        }
        return "/usr/local/bin/\(name)"
    }

    /// Result of running an external command.
    struct CommandResult {
        let exitCode: Int32
        let stdout: String
        let stderr: String
        var success: Bool { exitCode == 0 }
    }

    /// Runs an external command and returns the result. Must be called from a background queue.
    func runCommand(
        executable: String,
        arguments: [String],
        environment: [String: String]? = nil,
        timeout: TimeInterval = 30
    ) -> CommandResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if let env = environment {
            var merged = ProcessInfo.processInfo.environment
            for (k, v) in env { merged[k] = v }
            process.environment = merged
        }

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        // Concurrently drain both pipes — sequential `readDataToEndOfFile`
        // deadlocks when the unread pipe's buffer fills (~64KB on macOS).
        // This bit us with `docker build` producing huge stderr.
        var stdoutData = Data()
        var stderrData = Data()
        let dataLock = NSLock()
        let drainGroup = DispatchGroup()

        drainGroup.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            let data = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
            dataLock.lock(); stdoutData = data; dataLock.unlock()
            drainGroup.leave()
        }

        drainGroup.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            let data = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            dataLock.lock(); stderrData = data; dataLock.unlock()
            drainGroup.leave()
        }

        do {
            try process.run()
        } catch {
            return CommandResult(exitCode: -1, stdout: "", stderr: error.localizedDescription)
        }

        // Enforce timeout — kill the process if it overruns. This was previously a
        // silent no-op which caused stuck `imageBootstrapInProgress` flags.
        let deadline = DispatchTime.now() + timeout
        let timeoutQueue = DispatchQueue.global(qos: .utility)
        var timedOut = false
        let timeoutItem = DispatchWorkItem {
            if process.isRunning {
                timedOut = true
                process.terminate()
            }
        }
        timeoutQueue.asyncAfter(deadline: deadline, execute: timeoutItem)

        process.waitUntilExit()
        timeoutItem.cancel()
        _ = drainGroup.wait(timeout: .now() + 5) // give pipe drains a moment to finish

        dataLock.lock()
        let outStr = String(data: stdoutData, encoding: .utf8) ?? ""
        let errStr = String(data: stderrData, encoding: .utf8) ?? ""
        dataLock.unlock()

        return CommandResult(
            exitCode: process.terminationStatus,
            stdout: outStr,
            stderr: timedOut ? (errStr + "\n[command timed out after \(Int(timeout))s and was terminated]") : errStr
        )
    }

    /// Resolves the SSH connection target for any instance type.
    struct SSHTarget {
        let user: String
        let host: String
        let port: Int
        let keyPath: String
    }

    func resolveSSHTarget(for instance: CloudInstance) -> SSHTarget? {
        switch instance.type {
        case .ssh:
            guard let config = instance.sshConfig, !config.host.isEmpty else { return nil }
            return SSHTarget(user: config.user, host: config.host, port: config.port, keyPath: config.keyPath)
        case .ec2:
            guard let config = instance.ec2Config else { return nil }
            let ip = cloudInstanceRuntimeInfo[instance.id]?.publicIP ?? ""
            guard !ip.isEmpty else { return nil }
            return SSHTarget(user: config.sshUser, host: ip, port: 22, keyPath: config.sshKeyPath)
        case .fargate:
            guard let config = instance.fargateConfig else { return nil }
            let ip = cloudInstanceRuntimeInfo[instance.id]?.publicIP ?? ""
            guard !ip.isEmpty else { return nil }
            return SSHTarget(user: config.sshUser, host: ip, port: 22, keyPath: config.sshKeyPath)
        case .docker:
            guard let config = instance.dockerConfig else { return nil }
            return SSHTarget(user: config.sshUser, host: "localhost", port: config.sshPort, keyPath: config.sshKeyPath)
        }
    }

    /// Builds the full SSH command string for display/copy.
    func sshCommandString(for instance: CloudInstance) -> String? {
        guard let target = resolveSSHTarget(for: instance) else { return nil }
        var parts = ["ssh"]
        if target.port != 22 { parts += ["-p", "\(target.port)"] }
        if !target.keyPath.isEmpty { parts += ["-i", target.keyPath] }
        let userHost = target.user.isEmpty ? target.host : "\(target.user)@\(target.host)"
        parts.append(userHost)
        return parts.joined(separator: " ")
    }

    /// Resolves AWS environment variables for CLI commands.
    func resolveAWSEnvironment(for instance: CloudInstance) -> [String: String] {
        var env: [String: String] = [:]

        // Determine region
        let region: String
        switch instance.type {
        case .ec2: region = instance.ec2Config?.region ?? settings.awsDefaultRegion
        case .fargate: region = instance.fargateConfig?.region ?? settings.awsDefaultRegion
        default: region = settings.awsDefaultRegion
        }
        env["AWS_DEFAULT_REGION"] = region

        // Build list of project paths to check, prioritizing the explicitly chosen credentials project
        var projectPathsToCheck: [String] = []
        if !instance.awsCredentialsProjectPath.isEmpty {
            projectPathsToCheck.append(instance.awsCredentialsProjectPath)
        }
        for pid in instance.pairedProjectIds where !projectPathsToCheck.contains(pid) {
            projectPathsToCheck.append(pid)
        }

        // Check those project .env files for AWS keys (root .env and .claude/infra/.env)
        for projectId in projectPathsToCheck {
            let envPaths = [
                "\(projectId)/.env",
                "\(projectId)/\(Config.envFilePath)",
            ]
            for envPath in envPaths {
                guard let contents = try? String(contentsOfFile: envPath, encoding: .utf8) else { continue }
                for line in contents.components(separatedBy: .newlines) {
                    let trimmed = line.trimmingCharacters(in: .whitespaces)
                    guard !trimmed.hasPrefix("#"), trimmed.contains("=") else { continue }
                    let parts = trimmed.split(separator: "=", maxSplits: 1)
                    guard parts.count == 2 else { continue }
                    let key = String(parts[0]).trimmingCharacters(in: .whitespaces)
                    let value = String(parts[1]).trimmingCharacters(in: .whitespaces)
                    switch key {
                    case "AWS_ACCESS_KEY_ID", "AWS_ACCESS_KEY":
                        env["AWS_ACCESS_KEY_ID"] = value
                    case "AWS_SECRET_ACCESS_KEY", "AWS_ACCESS_TOKEN", "AWS_ACCESS_SECRET":
                        env["AWS_SECRET_ACCESS_KEY"] = value
                    case "AWS_SESSION_TOKEN":
                        env["AWS_SESSION_TOKEN"] = value
                    default: break
                    }
                }
                if env["AWS_ACCESS_KEY_ID"] != nil && env["AWS_SECRET_ACCESS_KEY"] != nil { break }
            }
            if env["AWS_ACCESS_KEY_ID"] != nil && env["AWS_SECRET_ACCESS_KEY"] != nil { break }
        }

        // Fall back to Keychain if no keys found in .env
        if env["AWS_ACCESS_KEY_ID"] == nil {
            if let creds = loadAWSCredentialsFromKeychain() {
                env["AWS_ACCESS_KEY_ID"] = creds.accessKey
                env["AWS_SECRET_ACCESS_KEY"] = creds.secretKey
            }
        }

        // If still no keys, let aws CLI use ~/.aws/credentials (don't set anything)
        return env
    }

    // MARK: - SSH Connection Test

    func testSSHConnection(for instance: CloudInstance, completion: @escaping (Bool, String) -> Void) {
        guard let target = resolveSSHTarget(for: instance) else {
            completion(false, "No SSH target configured")
            return
        }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            var args = ["-o", "BatchMode=yes", "-o", "ConnectTimeout=5", "-o", "StrictHostKeyChecking=accept-new"]
            if target.port != 22 { args += ["-p", "\(target.port)"] }
            if !target.keyPath.isEmpty {
                args += ["-i", (target.keyPath as NSString).expandingTildeInPath]
            }
            let userHost = target.user.isEmpty ? target.host : "\(target.user)@\(target.host)"
            args += [userHost, "echo", "ok"]

            let result = self.runCommand(executable: "/usr/bin/ssh", arguments: args, timeout: 10)
            DispatchQueue.main.async {
                if result.success {
                    completion(true, "Connected successfully")
                } else {
                    completion(false, result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
                }
            }
        }
    }

    // MARK: - EC2 Operations

    func ec2Describe(_ instance: CloudInstance, completion: @escaping (CloudInstanceStatus, String?) -> Void) {
        guard let config = instance.ec2Config, !config.instanceId.isEmpty else {
            completion(.unknown, nil)
            return
        }
        let env = resolveAWSEnvironment(for: instance)
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            let result = self.runCommand(
                executable: Self.resolveExecutable("aws"),
                arguments: ["ec2", "describe-instances", "--instance-ids", config.instanceId, "--region", config.region, "--output", "json"],
                environment: env
            )
            var status: CloudInstanceStatus = .unknown
            var ip: String?
            if result.success, let data = result.stdout.data(using: .utf8),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let reservations = json["Reservations"] as? [[String: Any]],
               let instances = reservations.first?["Instances"] as? [[String: Any]],
               let inst = instances.first {
                if let state = inst["State"] as? [String: Any], let name = state["Name"] as? String {
                    switch name {
                    case "running": status = .running
                    case "stopped": status = .stopped
                    case "pending": status = .starting
                    case "stopping": status = .stopping
                    case "terminated", "shutting-down": status = .terminated
                    default: status = .unknown
                    }
                }
                ip = inst["PublicIpAddress"] as? String
            }
            DispatchQueue.main.async {
                completion(status, ip)
            }
        }
    }

    func ec2Start(_ instance: CloudInstance, completion: @escaping (Bool, String) -> Void) {
        guard let config = instance.ec2Config, !config.instanceId.isEmpty else {
            completion(false, "No instance ID configured")
            return
        }
        cloudInstanceRuntimeInfo[instance.id] = CloudInstanceRuntimeInfo(status: .starting)
        let env = resolveAWSEnvironment(for: instance)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let result = self.runCommand(
                executable: Self.resolveExecutable("aws"),
                arguments: ["ec2", "start-instances", "--instance-ids", config.instanceId, "--region", config.region],
                environment: env
            )
            DispatchQueue.main.async {
                completion(result.success, result.success ? "Instance starting" : result.stderr)
            }
        }
    }

    func ec2Stop(_ instance: CloudInstance, completion: @escaping (Bool, String) -> Void) {
        guard let config = instance.ec2Config, !config.instanceId.isEmpty else {
            completion(false, "No instance ID configured")
            return
        }
        cloudInstanceRuntimeInfo[instance.id] = CloudInstanceRuntimeInfo(status: .stopping)
        let env = resolveAWSEnvironment(for: instance)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let result = self.runCommand(
                executable: Self.resolveExecutable("aws"),
                arguments: ["ec2", "stop-instances", "--instance-ids", config.instanceId, "--region", config.region],
                environment: env
            )
            DispatchQueue.main.async {
                completion(result.success, result.success ? "Instance stopping" : result.stderr)
            }
        }
    }

    func ec2Terminate(_ instance: CloudInstance, completion: @escaping (Bool, String) -> Void) {
        guard let config = instance.ec2Config, !config.instanceId.isEmpty else {
            completion(false, "No instance ID configured")
            return
        }
        closeTunnel(for: instance)

        // Show "Terminating..." right away — the button stays in pending state
        // until cleanup completes (could be ~2–5 min for SG/keys/.pem).
        cloudInstanceRuntimeInfo[instance.id] = CloudInstanceRuntimeInfo(status: .terminating)

        let env = resolveAWSEnvironment(for: instance)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let result = self.runCommand(
                executable: Self.resolveExecutable("aws"),
                arguments: ["ec2", "terminate-instances", "--instance-ids", config.instanceId, "--region", config.region],
                environment: env
            )

            if !result.success {
                DispatchQueue.main.async {
                    // Roll back state so user can retry
                    self.cloudInstanceRuntimeInfo[instance.id]?.status = .running
                    completion(false, result.stderr)
                }
                return
            }

            DispatchQueue.main.async {
                completion(true, "Terminating instance and cleaning up resources...")
            }

            // Run the cleanup synchronously on this background queue. Status stays
            // `.terminating` the entire time. Only flip to `.terminated` when fully done.
            self.runEC2ResourceCleanup(for: instance, env: env)
        }
    }

    /// Polls AWS until the instance reaches `terminated`, then deletes the security
    /// group, key pair, and local .pem file. SG can't be deleted while ENIs are
    /// still attached, so the wait is required. Updates status to `.terminated`
    /// only when the whole sequence finishes (or surfaces failures).
    private func runEC2ResourceCleanup(for instance: CloudInstance, env: [String: String]) {
        guard let config = instance.ec2Config else { return }
        let aws = Self.resolveExecutable("aws")
        let region = config.region
        let instanceId = config.instanceId
        let keyPair = config.keyPair
        let securityGroup = config.securityGroup
        let pemPath = config.sshKeyPath

        // Wait until the instance reaches `terminated` (max ~5 minutes)
        for _ in 0..<60 {
            Thread.sleep(forTimeInterval: 5)
            let describe = runCommand(
                executable: aws,
                arguments: ["ec2", "describe-instances", "--instance-ids", instanceId, "--region", region,
                            "--query", "Reservations[].Instances[].State.Name", "--output", "text"],
                environment: env,
                timeout: 30
            )
            if describe.success && describe.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "terminated" {
                break
            }
        }

        var report: [String] = []

        if !securityGroup.isEmpty {
            let res = runCommand(
                executable: aws,
                arguments: ["ec2", "delete-security-group", "--group-id", securityGroup, "--region", region],
                environment: env
            )
            report.append(res.success ? "✓ deleted SG \(securityGroup)" : "✗ SG \(securityGroup): \(res.stderr.prefix(80))")
        }

        if !keyPair.isEmpty {
            let res = runCommand(
                executable: aws,
                arguments: ["ec2", "delete-key-pair", "--key-name", keyPair, "--region", region],
                environment: env
            )
            report.append(res.success ? "✓ deleted key pair \(keyPair)" : "✗ key pair \(keyPair): \(res.stderr.prefix(80))")
        }

        if !pemPath.isEmpty {
            let expanded = (pemPath as NSString).expandingTildeInPath
            if FileManager.default.fileExists(atPath: expanded) {
                do {
                    try FileManager.default.removeItem(atPath: expanded)
                    report.append("✓ deleted local key \(expanded)")
                } catch {
                    report.append("✗ local key \(expanded): \(error.localizedDescription)")
                }
            }
        }

        logger.info("EC2 cleanup for \(instance.name, privacy: .public): \(report.joined(separator: ", "), privacy: .public)")

        DispatchQueue.main.async {
            self.cloudInstanceRuntimeInfo[instance.id] = CloudInstanceRuntimeInfo(status: .terminated)
        }
    }

    // MARK: - Fargate Operations

    func fargateDescribe(_ instance: CloudInstance, completion: @escaping (CloudInstanceStatus, String?) -> Void) {
        guard let config = instance.fargateConfig, !config.taskArn.isEmpty else {
            completion(.unknown, nil)
            return
        }
        let env = resolveAWSEnvironment(for: instance)
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            let result = self.runCommand(
                executable: Self.resolveExecutable("aws"),
                arguments: ["ecs", "describe-tasks", "--cluster", config.cluster, "--tasks", config.taskArn, "--region", config.region, "--output", "json"],
                environment: env
            )
            var status: CloudInstanceStatus = .unknown
            var ip: String?
            if result.success, let data = result.stdout.data(using: .utf8),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let tasks = json["tasks"] as? [[String: Any]],
               let task = tasks.first {
                if let lastStatus = task["lastStatus"] as? String {
                    switch lastStatus {
                    case "RUNNING": status = .running
                    case "PROVISIONING", "PENDING", "ACTIVATING": status = .starting
                    case "DEPROVISIONING", "STOPPING": status = .stopping
                    case "STOPPED": status = .stopped
                    default: status = .unknown
                    }
                }
                // Extract public IP from network attachments
                if let attachments = task["attachments"] as? [[String: Any]] {
                    for attachment in attachments {
                        if let details = attachment["details"] as? [[String: Any]] {
                            for detail in details {
                                if detail["name"] as? String == "networkInterfaceId",
                                   let _ = detail["value"] as? String {
                                    // IP comes from ENI — for now just check containers
                                }
                            }
                        }
                    }
                }
                if let containers = task["containers"] as? [[String: Any]],
                   let container = containers.first,
                   let networkInterfaces = container["networkInterfaces"] as? [[String: Any]],
                   let ni = networkInterfaces.first {
                    ip = ni["privateIpv4Address"] as? String
                }
            }
            DispatchQueue.main.async {
                completion(status, ip)
            }
        }
    }

    func fargateRunTask(_ instance: CloudInstance, completion: @escaping (Bool, String) -> Void) {
        guard let config = instance.fargateConfig, !config.cluster.isEmpty, !config.taskDefinition.isEmpty else {
            completion(false, "Cluster and task definition required")
            return
        }
        cloudInstanceRuntimeInfo[instance.id] = CloudInstanceRuntimeInfo(status: .starting)
        let env = resolveAWSEnvironment(for: instance)

        var args = ["ecs", "run-task",
                    "--cluster", config.cluster,
                    "--task-definition", config.taskDefinition,
                    "--region", config.region,
                    "--launch-type", "FARGATE",
                    "--output", "json"]

        if !config.subnets.isEmpty || !config.securityGroups.isEmpty {
            let subnetsStr = config.subnets.joined(separator: ",")
            let sgStr = config.securityGroups.joined(separator: ",")
            var netConfig = "awsvpcConfiguration={subnets=[\(subnetsStr)]"
            if !sgStr.isEmpty {
                netConfig += ",securityGroups=[\(sgStr)]"
            }
            netConfig += ",assignPublicIp=ENABLED}"
            args += ["--network-configuration", netConfig]
        }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let result = self.runCommand(executable: Self.resolveExecutable("aws"), arguments: args, environment: env)

            var taskArn: String?
            if result.success, let data = result.stdout.data(using: .utf8),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let tasks = json["tasks"] as? [[String: Any]],
               let task = tasks.first {
                taskArn = task["taskArn"] as? String
            }

            DispatchQueue.main.async {
                if let arn = taskArn {
                    // Update the instance's task ARN
                    if let index = self.cloudInstances.firstIndex(where: { $0.id == instance.id }) {
                        self.cloudInstances[index].fargateConfig?.taskArn = arn
                        self.saveCloudInstances()
                        if self.selectedCloudInstance?.id == instance.id {
                            self.selectedCloudInstance = self.cloudInstances[index]
                        }
                    }
                }
                completion(result.success, result.success ? "Task starting" : result.stderr)
            }
        }
    }

    func fargateStopTask(_ instance: CloudInstance, completion: @escaping (Bool, String) -> Void) {
        guard let config = instance.fargateConfig, !config.taskArn.isEmpty else {
            completion(false, "No task ARN")
            return
        }
        closeTunnel(for: instance)
        cloudInstanceRuntimeInfo[instance.id] = CloudInstanceRuntimeInfo(status: .stopping)
        let env = resolveAWSEnvironment(for: instance)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let result = self.runCommand(
                executable: Self.resolveExecutable("aws"),
                arguments: ["ecs", "stop-task", "--cluster", config.cluster, "--task", config.taskArn, "--region", config.region],
                environment: env
            )
            DispatchQueue.main.async {
                completion(result.success, result.success ? "Task stopping" : result.stderr)
            }
        }
    }

    // MARK: - Docker Operations

    func dockerInspect(_ instance: CloudInstance, completion: @escaping (CloudInstanceStatus) -> Void) {
        guard let config = instance.dockerConfig, !config.containerId.isEmpty else {
            completion(.unknown)
            return
        }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            let result = self.runCommand(
                executable: Self.resolveExecutable("docker"),
                arguments: ["inspect", "--format", "{{.State.Status}}", config.containerId]
            )
            var status: CloudInstanceStatus = .unknown
            if result.success {
                let state = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
                switch state {
                case "running": status = .running
                case "created", "restarting": status = .starting
                case "paused", "exited", "dead": status = .stopped
                default: status = .unknown
                }
            }
            DispatchQueue.main.async {
                completion(status)
            }
        }
    }

    func dockerRun(_ instance: CloudInstance, completion: @escaping (Bool, String) -> Void) {
        guard let config = instance.dockerConfig, !config.imageName.isEmpty else {
            completion(false, "Image name required")
            return
        }
        cloudInstanceRuntimeInfo[instance.id] = CloudInstanceRuntimeInfo(status: .starting)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            var args = ["run", "-d", "-p", "\(config.sshPort):22"]
            if !config.containerName.isEmpty {
                args += ["--name", config.containerName]
            }
            for vol in config.volumes where !vol.isEmpty {
                args += ["-v", vol]
            }
            args.append(config.imageName)

            let result = self.runCommand(executable: Self.resolveExecutable("docker"), arguments: args)

            DispatchQueue.main.async {
                if result.success {
                    let containerId = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
                    if let index = self.cloudInstances.firstIndex(where: { $0.id == instance.id }) {
                        self.cloudInstances[index].dockerConfig?.containerId = String(containerId.prefix(12))
                        self.saveCloudInstances()
                        self.cloudInstanceRuntimeInfo[instance.id] = CloudInstanceRuntimeInfo(status: .running)
                        if self.selectedCloudInstance?.id == instance.id {
                            self.selectedCloudInstance = self.cloudInstances[index]
                        }
                    }
                }
                completion(result.success, result.success ? "Container started" : result.stderr)
            }
        }
    }

    func dockerStart(_ instance: CloudInstance, completion: @escaping (Bool, String) -> Void) {
        guard let config = instance.dockerConfig, !config.containerId.isEmpty else {
            completion(false, "No container ID")
            return
        }
        cloudInstanceRuntimeInfo[instance.id] = CloudInstanceRuntimeInfo(status: .starting)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let result = self.runCommand(executable: Self.resolveExecutable("docker"), arguments: ["start", config.containerId])
            DispatchQueue.main.async {
                if result.success {
                    self.cloudInstanceRuntimeInfo[instance.id] = CloudInstanceRuntimeInfo(status: .running)
                }
                completion(result.success, result.success ? "Container started" : result.stderr)
            }
        }
    }

    func dockerStop(_ instance: CloudInstance, completion: @escaping (Bool, String) -> Void) {
        guard let config = instance.dockerConfig, !config.containerId.isEmpty else {
            completion(false, "No container ID")
            return
        }
        closeTunnel(for: instance)
        cloudInstanceRuntimeInfo[instance.id] = CloudInstanceRuntimeInfo(status: .stopping)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let result = self.runCommand(executable: Self.resolveExecutable("docker"), arguments: ["stop", config.containerId])
            DispatchQueue.main.async {
                if result.success {
                    self.cloudInstanceRuntimeInfo[instance.id] = CloudInstanceRuntimeInfo(status: .stopped)
                }
                completion(result.success, result.success ? "Container stopped" : result.stderr)
            }
        }
    }

    func dockerRemove(_ instance: CloudInstance, completion: @escaping (Bool, String) -> Void) {
        guard let config = instance.dockerConfig, !config.containerId.isEmpty else {
            completion(false, "No container ID")
            return
        }
        closeTunnel(for: instance)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let result = self.runCommand(executable: Self.resolveExecutable("docker"), arguments: ["rm", "-f", config.containerId])
            DispatchQueue.main.async {
                if result.success {
                    self.cloudInstanceRuntimeInfo[instance.id] = CloudInstanceRuntimeInfo(status: .terminated)
                }
                completion(result.success, result.success ? "Container removed" : result.stderr)
            }
        }
    }

    // MARK: - SSH Tunnel Management

    func openTunnel(for instance: CloudInstance, completion: @escaping (Bool, String) -> Void) {
        guard let target = resolveSSHTarget(for: instance) else {
            completion(false, "Cannot resolve SSH target")
            return
        }

        // Close existing tunnel first
        closeTunnel(for: instance)

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }

            var args = [
                "-L", "6080:localhost:6080",
                "-L", "2222:localhost:22",
                "-N", "-f",
                "-o", "ExitOnForwardFailure=yes",
                "-o", "ServerAliveInterval=30",
                "-o", "StrictHostKeyChecking=accept-new",
            ]
            if target.port != 22 { args += ["-p", "\(target.port)"] }
            if !target.keyPath.isEmpty {
                args += ["-i", (target.keyPath as NSString).expandingTildeInPath]
            }
            let userHost = target.user.isEmpty ? target.host : "\(target.user)@\(target.host)"
            args.append(userHost)

            let result = self.runCommand(executable: "/usr/bin/ssh", arguments: args, timeout: 15)

            // Find the SSH tunnel PID
            let pgrepResult = self.runCommand(
                executable: "/usr/bin/pgrep",
                arguments: ["-f", "ssh.*-L.*6080.*\(target.host)"]
            )
            let pid = Int32(pgrepResult.stdout.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: "\n").first ?? "")

            DispatchQueue.main.async {
                if result.success || pid != nil {
                    self.cloudInstanceRuntimeInfo[instance.id]?.tunnelPID = pid
                    completion(true, "Tunnel opened")
                } else {
                    completion(false, result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
                }
            }
        }
    }

    func closeTunnel(for instance: CloudInstance) {
        guard let pid = cloudInstanceRuntimeInfo[instance.id]?.tunnelPID else { return }
        kill(pid, SIGTERM)
        cloudInstanceRuntimeInfo[instance.id]?.tunnelPID = nil
    }

    var isTunnelOpen: Bool {
        guard let instance = selectedCloudInstance,
              let pid = cloudInstanceRuntimeInfo[instance.id]?.tunnelPID else { return false }
        return kill(pid, 0) == 0
    }

    // MARK: - Cloud Status Polling

    func pollCloudInstanceStatuses() {
        for instance in cloudInstances {
            let info = cloudInstanceRuntimeInfo[instance.id] ?? CloudInstanceRuntimeInfo()
            // Skip terminated instances and ones currently being terminated by us
            // (the terminate flow runs its own poll loop). Transitional states
            // like .starting/.stopping MUST be re-polled or they get stuck forever.
            if info.status == .terminated || info.status == .terminating { continue }

            switch instance.type {
            case .ssh:
                // SSH instances don't have a lifecycle to poll — just verify connectivity if marked running
                break
            case .ec2:
                guard let config = instance.ec2Config, !config.instanceId.isEmpty else { continue }
                ec2Describe(instance) { [weak self] status, ip in
                    guard let self else { return }
                    var updated = self.cloudInstanceRuntimeInfo[instance.id] ?? CloudInstanceRuntimeInfo()
                    updated.status = status
                    updated.publicIP = ip
                    if status != .running { updated.setupPhase = .bootingHost }
                    self.cloudInstanceRuntimeInfo[instance.id] = updated
                    // Probe setup phase if running and not yet ready
                    if status == .running, ip != nil, updated.setupPhase != .ready {
                        self.probeEC2SetupPhase(for: instance)
                    }
                }
            case .fargate:
                guard let config = instance.fargateConfig, !config.taskArn.isEmpty else { continue }
                fargateDescribe(instance) { [weak self] status, ip in
                    guard let self else { return }
                    var updated = self.cloudInstanceRuntimeInfo[instance.id] ?? CloudInstanceRuntimeInfo()
                    updated.status = status
                    updated.publicIP = ip
                    self.cloudInstanceRuntimeInfo[instance.id] = updated
                }
            case .docker:
                guard let config = instance.dockerConfig, !config.containerId.isEmpty else { continue }
                dockerInspect(instance) { [weak self] status in
                    guard let self else { return }
                    var updated = self.cloudInstanceRuntimeInfo[instance.id] ?? CloudInstanceRuntimeInfo()
                    updated.status = status
                    self.cloudInstanceRuntimeInfo[instance.id] = updated
                }
            }
        }
    }

    // MARK: - Rsync Project Sync

    enum SyncDirection {
        case push // local to remote
        case pull // remote to local
    }

    /// Builds the rsync argument list for syncing a project to/from an instance.
    func buildRsyncArgs(project: Project, instance: CloudInstance, direction: SyncDirection) -> [String]? {
        guard let target = resolveSSHTarget(for: instance) else { return nil }

        let remotePath = instance.syncConfig.remotePath
        let remoteDir = "\(remotePath)/\(project.name)/"

        // Build SSH transport string
        var sshCmd = "ssh"
        if target.port != 22 { sshCmd += " -p \(target.port)" }
        if !target.keyPath.isEmpty {
            sshCmd += " -i \((target.keyPath as NSString).expandingTildeInPath)"
        }
        sshCmd += " -o StrictHostKeyChecking=accept-new"

        let userHost = target.user.isEmpty ? target.host : "\(target.user)@\(target.host)"

        var args = ["-avz", "--delete", "-e", sshCmd]

        // Add .claudehubignore if it exists
        let ignorePath = "\(project.path)/.claudehubignore"
        if FileManager.default.fileExists(atPath: ignorePath) {
            args += ["--exclude-from", ignorePath]
        }

        // Add per-instance SyncConfig excludes
        for exclude in instance.syncConfig.excludes {
            args += ["--exclude", exclude]
        }

        switch direction {
        case .push:
            args.append("\(project.path)/")
            args.append("\(userHost):\(remoteDir)")
        case .pull:
            args.append("\(userHost):\(remoteDir)")
            args.append("\(project.path)/")
        }

        return args
    }

    /// Syncs a project to/from a cloud instance using rsync.
    func syncProject(_ project: Project, to instance: CloudInstance, direction: SyncDirection, completion: @escaping (Bool, String) -> Void) {
        guard let args = buildRsyncArgs(project: project, instance: instance, direction: direction) else {
            completion(false, "Cannot resolve SSH target")
            return
        }

        // Mark syncing
        var info = cloudInstanceRuntimeInfo[instance.id] ?? CloudInstanceRuntimeInfo()
        info.isSyncing = true
        cloudInstanceRuntimeInfo[instance.id] = info

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }

            // Ensure remote directory exists for push
            if direction == .push, let target = self.resolveSSHTarget(for: instance) {
                let remotePath = instance.syncConfig.remotePath
                let remoteDir = "\(remotePath)/\(project.name)"
                let userHost = target.user.isEmpty ? target.host : "\(target.user)@\(target.host)"
                var mkdirSSHArgs = ["-o", "StrictHostKeyChecking=accept-new"]
                if target.port != 22 { mkdirSSHArgs += ["-p", "\(target.port)"] }
                if !target.keyPath.isEmpty {
                    mkdirSSHArgs += ["-i", (target.keyPath as NSString).expandingTildeInPath]
                }
                mkdirSSHArgs += [userHost, "mkdir", "-p", remoteDir]
                _ = self.runCommand(executable: "/usr/bin/ssh", arguments: mkdirSSHArgs)
            }

            let result = self.runCommand(executable: "/usr/bin/rsync", arguments: args, timeout: 300)

            // Post-rsync (push only): rewrite .mcp.json on remote so paths point
            // inside the container (gateway at /opt/claudehub/gateway, project at /workspace/<name>).
            if result.success && direction == .push {
                self.rewriteRemoteMCPConfig(project: project, instance: instance)
            }

            DispatchQueue.main.async {
                var updatedInfo = self.cloudInstanceRuntimeInfo[instance.id] ?? CloudInstanceRuntimeInfo()
                updatedInfo.isSyncing = false
                if result.success {
                    updatedInfo.lastSyncDate = Date()
                    updatedInfo.lastSyncError = nil
                } else {
                    updatedInfo.lastSyncError = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                }
                self.cloudInstanceRuntimeInfo[instance.id] = updatedInfo
                completion(result.success, result.success ? "Sync complete" : result.stderr)
            }
        }
    }

    /// Rewrites the just-rsynced `.mcp.json` AND `.claude/infra/gateway.config.json`
    /// on the remote so paths resolve inside the container.
    private func rewriteRemoteMCPConfig(project: Project, instance: CloudInstance) {
        let containerProjectPath = "/workspace/\(project.name)"

        // 1) .mcp.json — top-level Claude config that points at the gateway
        if let rewritten = rewrittenMCPJson(at: "\(project.path)/.mcp.json",
                                            hostProjectPath: project.path,
                                            containerProjectPath: containerProjectPath) {
            uploadToRemote(rewritten, remotePath: "\(instance.syncConfig.remotePath)/\(project.name)/.mcp.json", instance: instance)
        }

        // 2) gateway.config.json — the actual upstream-spawn config (this is what
        //    bites us with /Users/.../nvm/.../npx ENOENT inside the container)
        let gatewayConfigPath = "\(project.path)/.claude/infra/gateway.config.json"
        if let rewritten = rewrittenGatewayConfig(at: gatewayConfigPath,
                                                  hostProjectPath: project.path,
                                                  containerProjectPath: containerProjectPath) {
            uploadToRemote(rewritten, remotePath: "\(instance.syncConfig.remotePath)/\(project.name)/.claude/infra/gateway.config.json", instance: instance)
        }
    }

    /// Rewrites `.mcp.json` for the container — gateway path, node binary, env vars.
    private func rewrittenMCPJson(at path: String, hostProjectPath: String, containerProjectPath: String) -> Data? {
        guard FileManager.default.fileExists(atPath: path),
              let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              var root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              var servers = root["mcpServers"] as? [String: Any]
        else { return nil }

        for (key, value) in servers {
            guard var server = value as? [String: Any] else { continue }

            // Container's PATH-resolved node
            server["command"] = "node"

            if var args = server["args"] as? [String] {
                args = args.map { arg in
                    if arg.hasSuffix("gateway/index.js") {
                        return "/opt/claudehub/gateway/index.js"
                    }
                    if arg.hasPrefix(hostProjectPath) {
                        return arg.replacingOccurrences(of: hostProjectPath, with: containerProjectPath)
                    }
                    return arg
                }
                server["args"] = args
            }

            if var env = server["env"] as? [String: String] {
                for (envKey, envVal) in env where envVal.hasPrefix(hostProjectPath) {
                    env[envKey] = envVal.replacingOccurrences(of: hostProjectPath, with: containerProjectPath)
                }
                server["env"] = env
            }

            servers[key] = server
        }

        root["mcpServers"] = servers
        return try? JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted])
    }

    /// Rewrites `.claude/infra/gateway.config.json` for the container — fixes
    /// hardcoded macOS paths (project root, nvm node/npx). This is the file that
    /// actually spawns the upstream MCP servers, so wrong paths here = ENOENT.
    private func rewrittenGatewayConfig(at path: String, hostProjectPath: String, containerProjectPath: String) -> Data? {
        guard FileManager.default.fileExists(atPath: path),
              let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              var root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              var servers = root["servers"] as? [String: Any]
        else { return nil }

        for (key, value) in servers {
            guard var server = value as? [String: Any] else { continue }

            // command: rewrite host project path → container path; nvm npx/node → bare name
            if let cmd = server["command"] as? String {
                server["command"] = remapBinaryPath(cmd, hostProjectPath: hostProjectPath, containerProjectPath: containerProjectPath)
            }

            if var args = server["args"] as? [String] {
                args = args.map { remapBinaryPath($0, hostProjectPath: hostProjectPath, containerProjectPath: containerProjectPath) }
                server["args"] = args
            }

            if var env = server["env"] as? [String: String] {
                for (envKey, envVal) in env where envVal.hasPrefix(hostProjectPath) {
                    env[envKey] = envVal.replacingOccurrences(of: hostProjectPath, with: containerProjectPath)
                }
                server["env"] = env
            }

            servers[key] = server
        }

        root["servers"] = servers
        return try? JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted])
    }

    /// Translates a host-side path/command into something that resolves inside
    /// the container. Handles three common cases:
    ///   - `<host project>/...`  → `/workspace/<project>/...`
    ///   - nvm-pinned `npx`/`node` → bare `npx`/`node` (PATH-resolved)
    ///   - everything else passes through
    private func remapBinaryPath(_ value: String, hostProjectPath: String, containerProjectPath: String) -> String {
        if value.hasPrefix(hostProjectPath) {
            return value.replacingOccurrences(of: hostProjectPath, with: containerProjectPath)
        }
        // nvm: /Users/<u>/.nvm/versions/node/<ver>/bin/<name>
        if value.contains("/.nvm/versions/node/") {
            return (value as NSString).lastPathComponent
        }
        // Other host-only Homebrew paths (rare, but cheap to handle)
        if value.hasPrefix("/Users/") && (value.hasSuffix("/npx") || value.hasSuffix("/node") || value.hasSuffix("/npm")) {
            return (value as NSString).lastPathComponent
        }
        return value
    }

    /// Uploads `data` to `remotePath` over SSH on the given instance.
    private func uploadToRemote(_ data: Data, remotePath: String, instance: CloudInstance) {
        guard let target = resolveSSHTarget(for: instance) else { return }
        let userHost = target.user.isEmpty ? target.host : "\(target.user)@\(target.host)"
        let b64 = data.base64EncodedString()
        let remoteDir = (remotePath as NSString).deletingLastPathComponent

        var sshArgs = ["-o", "StrictHostKeyChecking=accept-new"]
        if target.port != 22 { sshArgs += ["-p", "\(target.port)"] }
        if !target.keyPath.isEmpty {
            sshArgs += ["-i", (target.keyPath as NSString).expandingTildeInPath]
        }
        sshArgs += [userHost, "mkdir -p \(remoteDir) && echo \(b64) | base64 -d > \(remotePath)"]

        let res = runCommand(executable: "/usr/bin/ssh", arguments: sshArgs)
        if !res.success {
            logger.warning("Failed to upload \(remotePath, privacy: .public): \(res.stderr, privacy: .public)")
        }
    }

    // MARK: - Claude Desktop for Cloud Instance

    /// Settings directory for a cloud instance.
    func cloudSettingsDir(for instance: CloudInstance) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let safeName = instance.name
            .lowercased()
            .replacingOccurrences(of: " ", with: "-")
        return "\(home)/claude-cloud-\(safeName)"
    }

    /// Generates ssh_configs.json content for Claude Desktop.
    func generateSSHConfigsJSON(for instance: CloudInstance) -> Data? {
        guard let target = resolveSSHTarget(for: instance) else { return nil }

        let sshHost = target.user.isEmpty ? target.host : "\(target.user)@\(target.host)"
        let trustedHost = "\(sshHost):\(target.port)"

        var config: [String: Any] = [
            "id": instance.id.uuidString,
            "name": instance.name,
            "sshHost": sshHost,
            "sshPort": target.port,
        ]
        if !target.keyPath.isEmpty {
            config["sshIdentityFile"] = (target.keyPath as NSString).expandingTildeInPath
        }

        let root: [String: Any] = [
            "configs": [config],
            "trustedHosts": [trustedHost],
        ]

        return try? JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
    }

    /// Launches Claude Desktop with SSH connection pre-configured for a cloud instance.
    enum CloudLaunchMode {
        case cloudIsolated   // dedicated wrapper app per cloud instance
        case projectIsolated // use the project's own isolated Claude (must have project)
        case global          // use the global Claude (no --user-data-dir)
    }

    func launchClaudeForCloudInstance(_ instance: CloudInstance, project: Project? = nil, mode: CloudLaunchMode = .cloudIsolated) {
        let fm = FileManager.default

        switch mode {
        case .cloudIsolated:
            let settingsDir = cloudSettingsDir(for: instance)
            try? fm.createDirectory(atPath: settingsDir, withIntermediateDirectories: true)
            if let sshData = generateSSHConfigsJSON(for: instance) {
                try? sshData.write(to: URL(fileURLWithPath: "\(settingsDir)/ssh_configs.json"))
            }
            if let project = project {
                writeCloudDesktopConfig(for: project, settingsDir: settingsDir)
            }
            let wrapperApp = buildCloudWrapperApp(for: instance, settingsDir: settingsDir)
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
                process.arguments = ["-a", wrapperApp]
                process.standardOutput = FileHandle.nullDevice
                process.standardError = FileHandle.nullDevice
                try? process.run()
                process.waitUntilExit()
            }

        case .projectIsolated:
            // Use the project's existing isolated instance, but inject the SSH config
            guard let project = project else { return }
            let settingsDir = claudeSettingsDir(for: project)
            try? fm.createDirectory(atPath: settingsDir, withIntermediateDirectories: true)
            if let sshData = generateSSHConfigsJSON(for: instance) {
                try? sshData.write(to: URL(fileURLWithPath: "\(settingsDir)/ssh_configs.json"))
            }
            // Use the project's own launch flow (which builds its wrapper + writes its mcp config)
            launchClaudeForProject(project)

        case .global:
            // Inject SSH config into global Claude's settings dir
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            let globalDir = "\(home)/Library/Application Support/Claude"
            try? fm.createDirectory(atPath: globalDir, withIntermediateDirectories: true)
            if let sshData = generateSSHConfigsJSON(for: instance) {
                try? sshData.write(to: URL(fileURLWithPath: "\(globalDir)/ssh_configs.json"))
            }
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
                process.arguments = ["-a", "/Applications/Claude.app"]
                process.standardOutput = FileHandle.nullDevice
                process.standardError = FileHandle.nullDevice
                try? process.run()
                process.waitUntilExit()
            }
        }
    }

    /// Writes claude_desktop_config.json for a cloud instance + project.
    private func writeCloudDesktopConfig(for project: Project, settingsDir: String) {
        let configPath = "\(settingsDir)/claude_desktop_config.json"
        let projectPath = project.path.hasSuffix("/") ? String(project.path.dropLast()) : project.path
        let gatewayConfigPath = "\(projectPath)/\(Config.gatewayConfigPath)"
        let nodeCommand = resolveCommand("node", projectPath: projectPath)

        var mcpServers: [String: Any] = [:]
        for server in servers where server.enabled {
            mcpServers[server.name] = [
                "command": nodeCommand,
                "args": ["\(gatewayPath)/index.js"],
                "env": [
                    "MCP_GATEWAY_CONFIG": gatewayConfigPath,
                    "MCP_GATEWAY_SERVER": server.name,
                ],
            ] as [String: Any]
        }

        let config: [String: Any] = ["mcpServers": mcpServers]
        if let data = try? JSONSerialization.data(
            withJSONObject: config,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        ) {
            try? data.write(to: URL(fileURLWithPath: configPath))
        }
    }

    /// Builds a wrapper .app for a cloud instance (analogous to buildWrapperApp for projects).
    private func buildCloudWrapperApp(for instance: CloudInstance, settingsDir: String) -> String {
        let displayName = "Claude Cloud - \(instance.name)"
        let appDir = "\(Self.wrappersDir)/\(displayName).app"
        let contentsDir = "\(appDir)/Contents"
        let macosDir = "\(contentsDir)/MacOS"
        let resourcesDir = "\(contentsDir)/Resources"
        let fm = FileManager.default

        try? fm.createDirectory(atPath: macosDir, withIntermediateDirectories: true)
        try? fm.createDirectory(atPath: resourcesDir, withIntermediateDirectories: true)

        // Info.plist
        let bundleId = "com.claudehub.cloud.\(instance.name.lowercased().replacingOccurrences(of: " ", with: "-"))"
        let plist: [String: Any] = [
            "CFBundleName": displayName,
            "CFBundleDisplayName": displayName,
            "CFBundleIdentifier": bundleId,
            "CFBundleExecutable": "Claude",
            "CFBundleIconFile": "AppIcon",
            "CFBundlePackageType": "APPL",
            "CFBundleVersion": "\(Int(Date().timeIntervalSince1970))",
            "CFBundleShortVersionString": "1.0",
            "LSUIElement": false,
        ]
        (plist as NSDictionary).write(toFile: "\(contentsDir)/Info.plist", atomically: true)

        // Launcher
        let claudeApp = "/Applications/Claude.app"
        let claudeContents = "\(claudeApp)/Contents"
        let claudePath = Bundle(path: claudeApp)?.executablePath
            ?? "\(claudeContents)/MacOS/Claude"

        let launcherSrc = """
        #include <unistd.h>
        int main(int argc, char *argv[]) {
            char *args[] = {"\(claudePath)", "--user-data-dir=\(settingsDir)", 0};
            return execv("\(claudePath)", args);
        }
        """
        let srcPath = "\(macosDir)/launcher.c"
        let binPath = "\(macosDir)/Claude"
        try? launcherSrc.write(toFile: srcPath, atomically: true, encoding: .utf8)

        let needsCompile: Bool
        if fm.fileExists(atPath: binPath),
           let srcDate = (try? fm.attributesOfItem(atPath: srcPath))?[.modificationDate] as? Date,
           let binDate = (try? fm.attributesOfItem(atPath: binPath))?[.modificationDate] as? Date,
           binDate > srcDate {
            needsCompile = false
        } else {
            needsCompile = true
        }

        if needsCompile {
            try? fm.removeItem(atPath: binPath)
            let cc = Process()
            cc.executableURL = URL(fileURLWithPath: "/usr/bin/cc")
            cc.arguments = ["-O2", "-o", binPath, srcPath]
            cc.standardOutput = FileHandle.nullDevice
            cc.standardError = FileHandle.nullDevice
            if (try? cc.run()) != nil { cc.waitUntilExit() }
        }

        // Copy Claude icon
        let iconDest = "\(resourcesDir)/AppIcon.icns"
        if !fm.fileExists(atPath: iconDest) {
            let candidates = [
                "\(claudeContents)/Resources/AppIcon.icns",
                "\(claudeContents)/Resources/icon.icns",
                "\(claudeContents)/Resources/electron.icns",
            ]
            for candidate in candidates {
                if fm.fileExists(atPath: candidate) {
                    try? fm.copyItem(atPath: candidate, toPath: iconDest)
                    break
                }
            }
        }

        return appDir
    }

    // MARK: - Automation Discovery & Deployment

    /// A discovered scheduled task from ~/.claude/scheduled-tasks/.
    struct ScheduledTask: Identifiable {
        var id: String { name }
        let name: String
        let description: String
        let filePath: String
    }

    /// Discovers available SKILL.md files from ~/.claude/scheduled-tasks/.
    func discoverScheduledTasks() -> [ScheduledTask] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let tasksDir = "\(home)/.claude/scheduled-tasks"
        let fm = FileManager.default

        guard let taskDirs = try? fm.contentsOfDirectory(atPath: tasksDir) else { return [] }

        var tasks: [ScheduledTask] = []
        for dir in taskDirs {
            let skillPath = "\(tasksDir)/\(dir)/SKILL.md"
            guard fm.fileExists(atPath: skillPath) else { continue }
            guard let content = try? String(contentsOfFile: skillPath, encoding: .utf8) else { continue }

            // Parse YAML frontmatter
            var name = dir
            var description = ""
            if content.hasPrefix("---") {
                let parts = content.components(separatedBy: "---")
                if parts.count >= 3 {
                    let frontmatter = parts[1]
                    for line in frontmatter.components(separatedBy: .newlines) {
                        let trimmed = line.trimmingCharacters(in: .whitespaces)
                        if trimmed.hasPrefix("name:") {
                            name = String(trimmed.dropFirst(5)).trimmingCharacters(in: .whitespaces)
                        } else if trimmed.hasPrefix("description:") {
                            description = String(trimmed.dropFirst(12)).trimmingCharacters(in: .whitespaces)
                        }
                    }
                }
            }

            tasks.append(ScheduledTask(name: name, description: description, filePath: skillPath))
        }
        return tasks
    }

    /// Builds a crontab entry for a scheduled task.
    /// For containerized instances (EC2/Fargate with Docker image), runs Claude inside the container via docker exec.
    func buildCrontabEntry(task: ScheduledTask, cronExpression: String, remotePath: String, projectName: String, useContainer: Bool = true) -> String {
        let taskDir = (task.filePath as NSString).deletingLastPathComponent
        let taskName = (taskDir as NSString).lastPathComponent

        if useContainer {
            // Cron runs on host, but Claude runs inside the container where Chrome/Playwright/etc are installed.
            // Project files are at /workspace/<projectName> inside the container (mapped from host's /home/ubuntu/projects).
            let containerSkill = "/workspace/.claudehub-tasks/\(taskName)/SKILL.md"
            return "\(cronExpression) docker exec claudehub bash -c 'cd /workspace/\(projectName) && claude -p \"$(cat \(containerSkill))\" --permission-mode dontAsk'"
        } else {
            let skillPath = "~/.claude/scheduled-tasks/\(taskName)/SKILL.md"
            return "\(cronExpression) cd \(remotePath)/\(projectName) && claude -p \"$(cat \(skillPath))\" --permission-mode dontAsk"
        }
    }

    /// Deploys automation tasks to a remote instance.
    func deployAutomations(
        to instance: CloudInstance,
        tasks: [(task: ScheduledTask, cronExpression: String)],
        projectName: String,
        completion: @escaping (Bool, String) -> Void
    ) {
        guard let target = resolveSSHTarget(for: instance) else {
            completion(false, "Cannot resolve SSH target")
            return
        }
        guard !tasks.isEmpty else {
            completion(false, "No tasks selected")
            return
        }

        let remotePath = instance.syncConfig.remotePath

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }

            // Step 1: Sync scheduled-tasks directory to remote
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            let tasksDir = "\(home)/.claude/scheduled-tasks/"
            let userHost = target.user.isEmpty ? target.host : "\(target.user)@\(target.host)"

            var sshCmd = "ssh -o StrictHostKeyChecking=accept-new"
            if target.port != 22 { sshCmd += " -p \(target.port)" }
            if !target.keyPath.isEmpty {
                sshCmd += " -i \((target.keyPath as NSString).expandingTildeInPath)"
            }

            // Ensure remote dir exists — sync to host's projects dir which is mounted into the container at /workspace
            var mkdirArgs = ["-o", "StrictHostKeyChecking=accept-new"]
            if target.port != 22 { mkdirArgs += ["-p", "\(target.port)"] }
            if !target.keyPath.isEmpty {
                mkdirArgs += ["-i", (target.keyPath as NSString).expandingTildeInPath]
            }
            mkdirArgs += [userHost, "mkdir", "-p", "~/projects/.claudehub-tasks"]
            _ = self.runCommand(executable: "/usr/bin/ssh", arguments: mkdirArgs)

            // Sync task files into the workspace (so they're accessible inside the container at /workspace/.claudehub-tasks)
            if FileManager.default.fileExists(atPath: tasksDir) {
                let rsyncArgs = ["-avz", "-e", sshCmd, tasksDir, "\(userHost):~/projects/.claudehub-tasks/"]
                _ = self.runCommand(executable: "/usr/bin/rsync", arguments: rsyncArgs, timeout: 60)
            }

            // Step 2: Build crontab content
            var crontabLines: [String] = [
                "# Claude Hub automated tasks - deployed \(ISO8601DateFormatter().string(from: Date()))",
                "SHELL=/bin/bash",
                "PATH=/usr/local/bin:/usr/bin:/bin",
                "",
            ]
            for entry in tasks {
                let line = self.buildCrontabEntry(
                    task: entry.task,
                    cronExpression: entry.cronExpression,
                    remotePath: remotePath,
                    projectName: projectName
                )
                crontabLines.append(line)
            }
            let crontabContent = crontabLines.joined(separator: "\n") + "\n"

            // Step 3: Install crontab via SSH
            // Write to temp file locally, pipe to remote crontab
            let tempFile = NSTemporaryDirectory() + "claudehub_crontab_\(UUID().uuidString)"
            try? crontabContent.write(toFile: tempFile, atomically: true, encoding: .utf8)

            var sshArgs = ["-o", "StrictHostKeyChecking=accept-new"]
            if target.port != 22 { sshArgs += ["-p", "\(target.port)"] }
            if !target.keyPath.isEmpty {
                sshArgs += ["-i", (target.keyPath as NSString).expandingTildeInPath]
            }
            sshArgs += [userHost, "crontab", "-"]

            // Use bash to pipe file into ssh
            let bashResult = self.runCommand(
                executable: "/bin/bash",
                arguments: ["-c", "cat '\(tempFile)' | ssh \(sshArgs.map { "'\($0)'" }.joined(separator: " "))"],
                timeout: 30
            )

            try? FileManager.default.removeItem(atPath: tempFile)

            DispatchQueue.main.async {
                completion(bashResult.success, bashResult.success ? "Automations deployed" : bashResult.stderr)
            }
        }
    }

    /// Returns paired cloud instances for a given project.
    func cloudInstancesForProject(_ project: Project) -> [CloudInstance] {
        cloudInstances.filter { $0.pairedProjectIds.contains(project.id) }
    }

    // MARK: - AWS Keychain

    func saveAWSCredentialsToKeychain(accessKey: String, secretKey: String) -> Bool {
        let credentials = "\(accessKey):\(secretKey)"
        guard let data = credentials.data(using: .utf8) else { return false }

        // Delete existing
        let deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Config.awsKeychainService,
            kSecAttrAccount as String: "default",
        ]
        SecItemDelete(deleteQuery as CFDictionary)

        // Add new
        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Config.awsKeychainService,
            kSecAttrAccount as String: "default",
            kSecValueData as String: data,
        ]
        let status = SecItemAdd(addQuery as CFDictionary, nil)
        return status == errSecSuccess
    }

    struct AWSCredentials {
        let accessKey: String
        let secretKey: String
    }

    func loadAWSCredentialsFromKeychain() -> AWSCredentials? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Config.awsKeychainService,
            kSecAttrAccount as String: "default",
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess,
              let data = result as? Data,
              let str = String(data: data, encoding: .utf8) else { return nil }

        let parts = str.split(separator: ":", maxSplits: 1)
        guard parts.count == 2 else { return nil }
        return AWSCredentials(accessKey: String(parts[0]), secretKey: String(parts[1]))
    }

    func deleteAWSCredentialsFromKeychain() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Config.awsKeychainService,
            kSecAttrAccount as String: "default",
        ]
        SecItemDelete(query as CFDictionary)
    }

    // MARK: - Utilities

    private func showNotification(title: String, body: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = [
            "-e",
            "display notification \"\(body)\" with title \"\(title)\""
        ]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try? process.run()
        process.waitUntilExit()
    }

    func openProject(_ project: Project) {
        NSWorkspace.shared.open(URL(fileURLWithPath: project.path))
    }
}
