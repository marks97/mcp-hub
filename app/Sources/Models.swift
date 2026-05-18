import Foundation

// MARK: - Badge Icon

/// Badge overlay for a project's Dock icon.
enum BadgeIcon: Codable, Hashable {
    case none
    case sfSymbol(String)
    case customImage(String) // filename in app support directory

    private enum CodingKeys: String, CodingKey {
        case type, value
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        switch type {
        case "sfSymbol":
            self = .sfSymbol(try container.decode(String.self, forKey: .value))
        case "customImage":
            self = .customImage(try container.decode(String.self, forKey: .value))
        default:
            self = .none
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .none:
            try container.encode("none", forKey: .type)
        case .sfSymbol(let name):
            try container.encode("sfSymbol", forKey: .type)
            try container.encode(name, forKey: .value)
        case .customImage(let filename):
            try container.encode("customImage", forKey: .type)
            try container.encode(filename, forKey: .value)
        }
    }
}

/// A project directory that contains MCP server configurations.
struct Project: Identifiable, Codable, Hashable {
    var id: String { path }
    let name: String
    let path: String
    var badgeIcon: BadgeIcon

    init(name: String, path: String, badgeIcon: BadgeIcon = .none) {
        self.name = name
        self.path = path
        self.badgeIcon = badgeIcon
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        path = try container.decode(String.self, forKey: .path)
        badgeIcon = try container.decodeIfPresent(BadgeIcon.self, forKey: .badgeIcon) ?? .none
    }
}

/// Configuration for a single MCP server as read from .mcp.json.
struct MCPServerConfig: Codable {
    let command: String?
    let args: [String]?
    let env: [String: String]?
    // HTTP-type servers (e.g. PostHog)
    let type: String?
    let url: String?
    let headersHelper: String?
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
    // HTTP-type servers bypass the gateway
    let serverType: String?
    let url: String?
    let headersHelper: String?

    var isHTTP: Bool { serverType == "http" }

    init(name: String, enabled: Bool, tools: [DiscoveredTool], command: String, args: [String], env: [String: String],
         serverType: String? = nil, url: String? = nil, headersHelper: String? = nil) {
        self.name = name
        self.enabled = enabled
        self.tools = tools
        self.command = command
        self.args = args
        self.env = env
        self.serverType = serverType
        self.url = url
        self.headersHelper = headersHelper
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
    var restartingSince: Date? = nil
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

    // Cloud defaults
    var awsDefaultRegion: String = "us-east-1"
    var defaultSSHKeyPath: String = ""
    var defaultDockerfilePath: String = ""

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

// MARK: - Cloud Instances

/// The type of cloud instance / remote environment.
enum CloudInstanceType: String, Codable, CaseIterable, Hashable {
    case ssh
    case ec2
    case fargate
    case docker

    var displayName: String {
        switch self {
        case .ssh: return "SSH"
        case .ec2: return "EC2"
        case .fargate: return "Fargate"
        case .docker: return "Docker"
        }
    }

    var iconName: String {
        switch self {
        case .ssh: return "terminal"
        case .ec2: return "server.rack"
        case .fargate: return "shippingbox"
        case .docker: return "cube"
        }
    }
}

/// Lifecycle status of a cloud instance.
enum CloudInstanceStatus: String, Codable, CaseIterable, Hashable {
    case stopped
    case starting
    case running
    case stopping
    case terminating  // AWS terminate-instances kicked off, cleanup pending
    case terminated
    case unknown

    var displayName: String {
        rawValue.capitalized
    }

    var color: String {
        switch self {
        case .running: return "green"
        case .starting, .stopping, .terminating: return "orange"
        case .stopped, .terminated: return "red"
        case .unknown: return "gray"
        }
    }
}

/// SSH connection configuration.
struct SSHConfig: Codable, Hashable {
    var host: String = ""
    var user: String = ""
    var port: Int = 22
    var keyPath: String = ""
}

/// AWS EC2 instance configuration.
struct EC2Config: Codable, Hashable {
    var instanceId: String = ""
    var region: String = "us-east-1"
    var instanceType: String = "t3.micro"
    var ami: String = ""
    var keyPair: String = ""
    var securityGroup: String = ""
    var sshUser: String = "ec2-user"
    var sshKeyPath: String = ""
}

/// AWS Fargate task configuration.
struct FargateConfig: Codable, Hashable {
    var cluster: String = ""
    var taskDefinition: String = ""
    var region: String = "us-east-1"
    var subnets: [String] = []
    var securityGroups: [String] = []
    var taskArn: String = ""
    var containerName: String = ""
    var sshUser: String = ""
    var sshKeyPath: String = ""
}

/// Local Docker container configuration.
struct DockerConfig: Codable, Hashable {
    var imageName: String = ""
    var containerName: String = ""
    var containerId: String = ""
    var sshPort: Int = 2222
    var sshUser: String = "root"
    var sshKeyPath: String = ""
    var volumes: [String] = []
}

/// File sync configuration for a cloud instance.
struct SyncConfig: Codable, Hashable {
    var excludes: [String] = SyncConfig.defaultExcludes
    var remotePath: String = "~/projects"

    static let defaultExcludes: [String] = [
        // Secrets — NEVER push these
        ".env",
        ".env.*",
        "*.pem",
        "*.key",
        "id_rsa",
        "id_ed25519",
        ".aws",
        // VCS
        ".git",
        // Dependencies / package caches (any depth)
        "**/node_modules",
        ".npm",
        ".yarn",
        ".pnp.*",
        "**/__pycache__",
        "**/.venv",
        "**/venv",
        "vendor",
        // Build output (any depth)
        "**/build",
        "**/dist",
        "**/out",
        "**/.next",
        "**/.nuxt",
        "**/.turbo",
        "**/.cache",
        "**/.parcel-cache",
        "**/.svelte-kit",
        "*.tsbuildinfo",
        // iOS / macOS native build
        "**/Pods",
        "**/DerivedData",
        "**/xcuserdata",
        // Android native build
        "**/.gradle",
        "**/.cxx",
        // React Native / Expo
        "**/.expo",
        "*.hbc",
        // Mobile binaries
        "*.apk",
        "*.aab",
        "*.ipa",
        // Test/coverage
        "**/coverage",
        ".nyc_output",
        // Browser data
        ".playwright-mcp",
        ".chromium",
        // IDE / OS
        ".DS_Store",
        ".idea",
        ".vscode",
        "Thumbs.db",
        // Logs
        "*.log",
        "logs",
        // Temp
        "tmp",
        "temp",
        ".tmp",
    ]
}

/// A cloud instance (remote machine or container) managed by the app.
struct CloudInstance: Identifiable, Codable, Hashable {
    let id: UUID
    var name: String
    var type: CloudInstanceType
    var sshConfig: SSHConfig?
    var ec2Config: EC2Config?
    var fargateConfig: FargateConfig?
    var dockerConfig: DockerConfig?
    var syncConfig: SyncConfig
    var pairedProjectIds: [String]
    /// Path of project whose .env supplies AWS credentials for this instance.
    /// Empty = use Keychain or ~/.aws/credentials.
    var awsCredentialsProjectPath: String
    /// Docker image to use when bootstrapping the container on this instance.
    /// nil = use the bundled default image.
    var dockerImageId: UUID?

    init(
        id: UUID = UUID(),
        name: String,
        type: CloudInstanceType,
        sshConfig: SSHConfig? = nil,
        ec2Config: EC2Config? = nil,
        fargateConfig: FargateConfig? = nil,
        dockerConfig: DockerConfig? = nil,
        syncConfig: SyncConfig = SyncConfig(),
        pairedProjectIds: [String] = [],
        awsCredentialsProjectPath: String = "",
        dockerImageId: UUID? = nil
    ) {
        self.id = id
        self.name = name
        self.type = type
        self.sshConfig = sshConfig
        self.ec2Config = ec2Config
        self.fargateConfig = fargateConfig
        self.dockerConfig = dockerConfig
        self.syncConfig = syncConfig
        self.pairedProjectIds = pairedProjectIds
        self.awsCredentialsProjectPath = awsCredentialsProjectPath
        self.dockerImageId = dockerImageId
    }

    enum CodingKeys: String, CodingKey {
        case id, name, type, sshConfig, ec2Config, fargateConfig, dockerConfig, syncConfig, pairedProjectIds, awsCredentialsProjectPath, dockerImageId
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        type = try c.decode(CloudInstanceType.self, forKey: .type)
        sshConfig = try c.decodeIfPresent(SSHConfig.self, forKey: .sshConfig)
        ec2Config = try c.decodeIfPresent(EC2Config.self, forKey: .ec2Config)
        fargateConfig = try c.decodeIfPresent(FargateConfig.self, forKey: .fargateConfig)
        dockerConfig = try c.decodeIfPresent(DockerConfig.self, forKey: .dockerConfig)
        syncConfig = try c.decode(SyncConfig.self, forKey: .syncConfig)
        pairedProjectIds = try c.decode([String].self, forKey: .pairedProjectIds)
        awsCredentialsProjectPath = try c.decodeIfPresent(String.self, forKey: .awsCredentialsProjectPath) ?? ""
        dockerImageId = try c.decodeIfPresent(UUID.self, forKey: .dockerImageId)
    }
}

// MARK: - Docker Images

/// A user-managed Docker image template (Dockerfile + entrypoint) used to
/// bootstrap the container on cloud instances. The bundled default ships with
/// Patchright + Chrome + VNC; users can duplicate it and tweak.
struct DockerImage: Identifiable, Codable, Hashable {
    let id: UUID
    var name: String
    var dockerfile: String
    var entrypoint: String
    /// Built-in image cannot be deleted or renamed. Users duplicate it to
    /// create their own variants.
    var isBuiltIn: Bool

    init(
        id: UUID = UUID(),
        name: String,
        dockerfile: String,
        entrypoint: String,
        isBuiltIn: Bool = false
    ) {
        self.id = id
        self.name = name
        self.dockerfile = dockerfile
        self.entrypoint = entrypoint
        self.isBuiltIn = isBuiltIn
    }
}

// MARK: - Cloud Instance Form Draft

/// Captured form state for the Create Instance sheet. Lives in AppState so the
/// form can be paused (when stacking modals like the Docker image editor) and
/// resumed without losing user input.
struct CloudInstanceDraft {
    var name: String = ""
    var instanceType: CloudInstanceType = .ec2
    var ec2Region: String = "us-east-1"
    var ec2InstanceType: String = "t3.small"
    var ec2VolumeGB: String = "30"
    var sshHost: String = ""
    var sshUser: String = ""
    var sshPort: String = "22"
    var sshKeyPath: String = ""
    var fargateRegion: String = "us-east-1"
    var fargateImage: String = ""
    var fargateUseDefault: Bool = true
    var fargateCpu: String = "1024"
    var fargateMemory: String = "2048"
    var dockerImage: String = "ubuntu:24.04"
    var dockerContainerName: String = ""
    var credentialsSource: String = ""
    var dockerImageId: UUID? = nil
}

/// Runtime state for a cloud instance (not persisted).
struct CloudInstanceRuntimeInfo {
    var status: CloudInstanceStatus = .unknown
    var publicIP: String? = nil
    var isSyncing: Bool = false
    var lastSyncDate: Date? = nil
    var lastSyncError: String? = nil
    var tunnelPID: Int32? = nil
    var setupPhase: SetupPhase = .unknown
}

/// Cloud-init / Docker readiness phase for EC2 instances.
/// Detected by SSH-polling once the EC2 lifecycle says `running`.
enum SetupPhase: String {
    case unknown          // not yet determined / not applicable
    case bootingHost      // EC2 is starting (pre-running)
    case installingDocker // running, but ~/.claudehub-host-ready is absent
    case buildingImage    // host-ready marker present, app is rsyncing build context + docker build
    case containerStarting // image built, container starting up
    case ready            // container running

    var displayName: String {
        switch self {
        case .unknown: return ""
        case .bootingHost: return "Booting host"
        case .installingDocker: return "Installing Docker"
        case .buildingImage: return "Building image"
        case .containerStarting: return "Starting container"
        case .ready: return "Ready"
        }
    }

    var isProgress: Bool {
        switch self {
        case .bootingHost, .installingDocker, .buildingImage, .containerStarting: return true
        case .ready, .unknown: return false
        }
    }
}
