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
