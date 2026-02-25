import Foundation
import Combine
import AppKit

/// Central application state managing projects, MCP server configurations,
/// and Claude Desktop lifecycle.
class AppState: ObservableObject {
    @Published var projects: [Project] = []
    @Published var selectedProject: Project?
    @Published var servers: [ServerState] = []
    @Published var isDiscovering = false
    @Published var isRestarting = false
    @Published var isProjectExpanded = true
    @Published var isClaudeRunning = false

    private let gatewayPath: String
    private var claudePollingTimer: Timer?

    private enum Config {
        static let claudeBundleId = "com.anthropic.claudefordesktop"
        static let userDefaultsKey = "savedProjects"
        static let mcpConfigPath = ".claude/infra/.mcp.json"
        static let gatewayConfigPath = ".claude/infra/gateway.config.json"
        static let envFilePath = ".claude/infra/.env"
        static let pollingInterval: TimeInterval = 3.0
        static let pollStep: TimeInterval = 0.5
        static let gracefulTerminationAttempts = 20
        static let forceTerminationAttempts = 10
        static let launchPollAttempts = 30
        static let processSettleDelay: TimeInterval = 2.0
        static let toolDiscoveryTimeout: TimeInterval = 15.0
    }

    init() {
        self.gatewayPath = Self.findGatewayPath()
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

    // MARK: - Claude Desktop Polling

    private func startClaudePolling() {
        claudePollingTimer = Timer.scheduledTimer(withTimeInterval: Config.pollingInterval, repeats: true) { [weak self] _ in
            guard let self, !self.isRestarting else { return }
            let running = self.findClaudeApp() != nil
            if running != self.isClaudeRunning {
                self.isClaudeRunning = running
            }
        }
    }

    // MARK: - Gateway Resolution

    private static func findGatewayPath() -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = [
            "\(home)/Documents/mcp-hub/gateway",
            "\(home)/mcp-hub/gateway",
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

    /// Loads saved projects from UserDefaults.
    func loadProjects() {
        if let data = UserDefaults.standard.data(forKey: Config.userDefaultsKey),
           let saved = try? JSONDecoder().decode([Project].self, from: data) {
            projects = saved
        }
    }

    /// Persists the current projects list to UserDefaults.
    func saveProjects() {
        if let data = try? JSONEncoder().encode(projects) {
            UserDefaults.standard.set(data, forKey: Config.userDefaultsKey)
        }
    }

    /// Presents a native folder picker dialog for adding a project.
    func showAddProject() {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-e", "return POSIX path of (choose folder with prompt \"Select a project folder\")"]

            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = Pipe()

            do {
                try process.run()
                process.waitUntilExit()

                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                if let path = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !path.isEmpty {
                    DispatchQueue.main.async {
                        self?.addProject(path: path)
                    }
                }
            } catch {}
        }
    }

    /// Adds a project at the given path if it contains an MCP configuration.
    func addProject(path: String) {
        let normalizedPath = path.hasSuffix("/") ? String(path.dropLast()) : path
        let name = (normalizedPath as NSString).lastPathComponent

        guard FileManager.default.fileExists(atPath: normalizedPath) else { return }

        let mcpConfigPath = "\(normalizedPath)/\(Config.mcpConfigPath)"
        guard FileManager.default.fileExists(atPath: mcpConfigPath) else { return }

        let project = Project(name: name, path: normalizedPath)
        if !projects.contains(where: { $0.path == normalizedPath }) {
            projects.append(project)
            saveProjects()
        }
        selectedProject = project
        loadServers(for: project)
    }

    /// Removes a project and updates selection if needed.
    func removeProject(_ project: Project) {
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

    /// Sets the active project and loads its server configurations.
    func selectProject(_ project: Project) {
        selectedProject = project
        loadServers(for: project)
    }

    // MARK: - Server Configuration

    /// Reads MCP and gateway config files to populate the servers list for a project.
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

    // MARK: - Tool Discovery

    /// Spawns each enabled server's MCP process to discover available tools.
    func discoverTools() {
        guard let project = selectedProject else { return }
        isDiscovering = true

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }

            for server in self.servers {
                guard server.enabled else { continue }

                let tools = self.discoverToolsForServer(server, projectPath: project.path)
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

        let process = Process()
        process.executableURL = URL(fileURLWithPath: command)
        process.arguments = server.args
        process.currentDirectoryURL = URL(fileURLWithPath: projectPath)

        var env = ProcessInfo.processInfo.environment
        for (k, v) in server.env { env[k] = v }
        loadEnvFile(into: &env, projectPath: projectPath)
        process.environment = env

        let stdin = Pipe()
        let stdout = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = Pipe()

        let jsonrpc = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"protocolVersion\":\"2024-11-05\",\"capabilities\":{},\"clientInfo\":{\"name\":\"mcphub\",\"version\":\"1.0.0\"}}}\n{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/list\",\"params\":{}}\n"

        do {
            try process.run()

            stdin.fileHandleForWriting.write(jsonrpc.data(using: .utf8)!)
            stdin.fileHandleForWriting.closeFile()

            let timer = DispatchSource.makeTimerSource()
            timer.schedule(deadline: .now() + Config.toolDiscoveryTimeout)
            timer.setEventHandler { process.terminate() }
            timer.resume()

            process.waitUntilExit()
            timer.cancel()

            let data = stdout.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8) ?? ""
            return parseToolsFromOutput(output)
        } catch {
            return []
        }
    }

    private func resolveCommand(_ command: String, projectPath: String) -> String {
        if command.hasPrefix("./") {
            return "\(projectPath)/\(command.dropFirst(2))"
        }
        if command.hasPrefix("/") {
            return command
        }
        let which = Process()
        which.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        which.arguments = [command]
        let pipe = Pipe()
        which.standardOutput = pipe
        which.standardError = Pipe()
        do {
            try which.run()
            which.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let resolved = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return resolved.isEmpty ? command : resolved
        } catch {
            return command
        }
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

    /// Writes the gateway configuration and root .mcp.json for the selected project.
    func saveConfig() {
        guard let project = selectedProject else { return }
        let gatewayConfigPath = "\(project.path)/\(Config.gatewayConfigPath)"
        let mcpJsonPath = "\(project.path)/.mcp.json"

        var gatewayServers: [String: GatewayServerConfig] = [:]

        for server in servers {
            let command = resolveCommand(server.command, projectPath: project.path)
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
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        if let data = try? encoder.encode(gatewayConfig) {
            try? data.write(to: URL(fileURLWithPath: gatewayConfigPath))
        }

        let mcpJson: [String: Any] = [
            "mcpServers": [
                "gateway": [
                    "command": "node",
                    "args": ["\(gatewayPath)/index.js"],
                    "env": [
                        "MCP_GATEWAY_CONFIG": gatewayConfigPath
                    ]
                ] as [String: Any]
            ]
        ]

        if let data = try? JSONSerialization.data(withJSONObject: mcpJson, options: [.prettyPrinted, .sortedKeys]) {
            try? FileManager.default.removeItem(atPath: mcpJsonPath)
            try? data.write(to: URL(fileURLWithPath: mcpJsonPath))
        }
    }

    // MARK: - Claude Desktop Lifecycle

    /// Saves configuration, terminates Claude Desktop, and relaunches it.
    func applyAndRestart() {
        guard !isRestarting else { return }
        saveConfig()
        isRestarting = true

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }

            self.terminateClaude()
            self.killStaleMCPProcesses()
            Thread.sleep(forTimeInterval: Config.processSettleDelay)
            self.launchClaudeAndWait()

            DispatchQueue.main.async {
                self.isClaudeRunning = self.findClaudeApp() != nil
                self.isRestarting = false
            }
        }
    }

    /// Launches Claude Desktop without terminating it first.
    func startClaude() {
        guard !isRestarting else { return }
        isRestarting = true

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            self.launchClaudeAndWait()

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

    private func launchClaudeAndWait() {
        let claudeURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: Config.claudeBundleId)
        if let url = claudeURL {
            let config = NSWorkspace.OpenConfiguration()
            config.activates = true
            let semaphore = DispatchSemaphore(value: 0)
            NSWorkspace.shared.openApplication(at: url, configuration: config) { _, _ in
                semaphore.signal()
            }
            semaphore.wait()
        }

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

    private func killStaleMCPProcesses() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        process.arguments = ["-f", "mcp-gateway"]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try? process.run()
        process.waitUntilExit()
    }

    /// Opens a project's directory in Finder.
    func openProject(_ project: Project) {
        NSWorkspace.shared.open(URL(fileURLWithPath: project.path))
    }
}
