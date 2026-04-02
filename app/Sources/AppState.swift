import Foundation
import Combine
import AppKit
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

    var anyProjectRestarting: Bool {
        isRestarting || projectInstances.values.contains { $0.isRestarting }
    }

    private let gatewayPath: String
    private var claudePollingTimer: Timer?
    private var lastDesktopConfigWriteDate: Date?

    private enum Config {
        static let claudeBundleId = "com.anthropic.claudefordesktop"
        static let userDefaultsKey = "savedProjects"
        static let settingsKey = "appSettings"
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
        if let first = projects.first {
            selectedProject = first
            loadServers(for: first)
        }
        startClaudePolling()
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
        selectedProject = project
        loadServers(for: project)

        // Ensure desktop config has our servers, then initialize sync state
        writeDesktopConfig(for: project)
        syncFromDesktopConfig(for: project)
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
                env: env
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

        for server in servers {
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

        // One gateway entry per enabled server
        let nodeCommand = resolveCommand("node", projectPath: projectPath)
        var mcpServerEntries: [String: Any] = [:]
        for server in servers where server.enabled {
            mcpServerEntries[server.name] = [
                "command": nodeCommand,
                "args": ["\(gatewayPath)/index.js"],
                "env": [
                    "MCP_GATEWAY_CONFIG": gatewayConfigPath,
                    "MCP_GATEWAY_SERVER": server.name
                ]
            ] as [String: Any]
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
