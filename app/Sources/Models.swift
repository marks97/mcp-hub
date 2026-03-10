import Foundation

/// A project directory that contains MCP server configurations.
struct Project: Identifiable, Codable, Hashable {
    var id: String { path }
    let name: String
    let path: String
}

/// Configuration for a single MCP server as read from .mcp.json.
struct MCPServerConfig: Codable {
    let command: String?
    let args: [String]?
    let env: [String: String]?
}

/// Container for the mcpServers dictionary in .mcp.json.
struct MCPConfig: Codable {
    let mcpServers: [String: MCPServerConfig]
}

/// Configuration for a server in the gateway config file, including tool filtering.
struct GatewayServerConfig: Codable {
    var enabled: Bool
    let command: String
    let args: [String]
    var env: [String: String]?
    var tools: ToolsFilter
    var discoveredTools: [String]?

    /// Encodes as "*" for all tools or as an array of specific tool names.
    enum ToolsFilter: Codable {
        case all
        case specific([String])

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let str = try? container.decode(String.self), str == "*" {
                self = .all
            } else {
                self = .specific(try container.decode([String].self))
            }
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            switch self {
            case .all:
                try container.encode("*")
            case .specific(let tools):
                try container.encode(tools)
            }
        }
    }
}

/// Root structure of the gateway.config.json file.
struct GatewayConfig: Codable {
    var servers: [String: GatewayServerConfig]
}

/// A tool discovered from an MCP server, with an enable/disable toggle.
struct DiscoveredTool: Identifiable, Hashable {
    var id: String { name }
    let name: String
    let description: String
    var enabled: Bool
}

/// Observable state for a single MCP server, including its tools and enabled status.
class ServerState: ObservableObject, Identifiable {
    var id: String { name }
    let name: String
    @Published var enabled: Bool
    @Published var tools: [DiscoveredTool]
    @Published var isExpanded: Bool = false
    let command: String
    let args: [String]
    let env: [String: String]

    init(name: String, enabled: Bool, tools: [DiscoveredTool], command: String, args: [String], env: [String: String]) {
        self.name = name
        self.enabled = enabled
        self.tools = tools
        self.command = command
        self.args = args
        self.env = env
    }

    var enabledToolCount: Int {
        tools.filter(\.enabled).count
    }
}

// MARK: - Per-Project Claude Instance

/// Tracks the Claude Desktop instance state for a single project.
struct ProjectInstanceInfo {
    var isRunning: Bool = false
    var isRestarting: Bool = false
    var pid: Int32? = nil
}

// MARK: - App Settings

/// Persisted application settings.
struct AppSettings: Codable {
    var registryURLs: [String] = ["https://registry.modelcontextprotocol.io/v0.1/servers"]
    /// Text prepended to the project name in the Dock (e.g. "Claude - ").
    var isolationPrefix: String = ""
    /// Text appended to the project name in the Dock (e.g. " (Claude)").
    var isolationSuffix: String = ""

    /// Builds the display name shown in the Dock for an isolated instance.
    func isolationDisplayName(for projectName: String) -> String {
        let name = "\(isolationPrefix)\(projectName)\(isolationSuffix)"
        return name.isEmpty ? projectName : name
    }
}

// MARK: - MCP Registry API

struct RegistrySearchResponse: Codable {
    let servers: [RegistryServer]?
    let metadata: RegistryMetadata?
}

struct RegistryServer: Identifiable, Codable {
    var id: String { "\(server.name)-\(server.version ?? "")" }
    let server: RegistryServerDetail
}

struct RegistryServerDetail: Codable {
    let name: String
    let description: String?
    let title: String?
    let version: String?
    let packages: [RegistryPackage]?
    let icons: [RegistryIcon]?

    /// Display name: use title if available, otherwise the last path component of the name.
    var displayName: String {
        if let title, !title.isEmpty { return title }
        return name.components(separatedBy: "/").last ?? name
    }

    /// First available icon URL.
    var iconURL: URL? {
        guard let src = icons?.first?.src else { return nil }
        return URL(string: src)
    }
}

struct RegistryIcon: Codable {
    let src: String
    let mimeType: String?
    let sizes: [String]?
    let theme: String?
}

struct RegistryPackage: Codable {
    let registryType: String
    let identifier: String
    let packageArguments: [RegistryArgument]?
}

struct RegistryArgument: Codable {
    let name: String
    let description: String?
    let isRequired: Bool?
}

struct RegistryMetadata: Codable {
    let nextCursor: String?
    let count: Int?
}
