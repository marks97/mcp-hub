# MCPHub

A macOS menu bar app that manages [Model Context Protocol](https://modelcontextprotocol.io) (MCP) server configurations for Claude Desktop. Toggle servers and individual tools on/off, scan for available tools, and apply changes with a single click — no manual JSON editing required.

## Features

- **Multi-project support** — manage MCP configs across different project directories
- **Per-tool toggles** — enable or disable individual tools within each server
- **Tool discovery** — auto-detect available tools by spawning each server's MCP process
- **Gateway proxy** — a lightweight Node.js gateway that aggregates enabled servers into a single MCP endpoint
- **One-click restart** — apply config changes and restart Claude Desktop without leaving the menu bar
- **Launch at login** — installs as a proper macOS app with a LaunchAgent

## Prerequisites

- macOS 14 (Sonoma) or later
- [Node.js](https://nodejs.org) 18+
- [Swift](https://swift.org) 5.9+ (included with Xcode 15+)
- [Claude Desktop](https://claude.ai/download)

## Installation

```bash
git clone https://github.com/marks97/mcp-hub.git
cd mcp-hub
./install.sh
```

The install script will:
1. Install gateway npm dependencies
2. Build the Swift app in release mode
3. Create `MCPHub.app` in `/Applications`
4. Register a LaunchAgent so it starts at login
5. Launch the app

## How It Works

### Project Structure

```
mcp-hub/
├── app/                    # SwiftUI menu bar application
│   ├── Sources/
│   │   ├── MCPHubApp.swift     # App entry point
│   │   ├── AppState.swift      # Core state management
│   │   ├── Models.swift        # Data models
│   │   ├── MenuBarView.swift   # Main UI views
│   │   ├── ServerCardView.swift # Server and tool cards
│   │   └── Theme.swift         # Visual constants
│   ├── Package.swift
│   └── Info.plist
├── gateway/                # Node.js MCP gateway proxy
│   ├── index.js
│   └── package.json
├── install.sh              # Build + install script
└── README.md
```

### Architecture

Each project you add must have a `.claude/infra/.mcp.json` file listing its MCP servers. MCPHub reads this file, lets you toggle servers/tools via the menu bar UI, and writes two config files:

1. **`gateway.config.json`** — tells the gateway which servers to connect and which tools to expose
2. **`.mcp.json`** (project root) — points Claude Desktop at the gateway as its single MCP server

The **gateway** (`gateway/index.js`) is a Node.js process that:
- Connects to each enabled upstream MCP server as a client
- Registers only the enabled tools from each server
- Proxies tool calls from Claude Desktop to the appropriate upstream server
- Handles tool name collisions across servers (first-registered wins)

When you click "Apply & Restart", MCPHub saves the config, terminates Claude Desktop gracefully, kills any stale gateway processes, and relaunches Claude — which picks up the new `.mcp.json` and starts a fresh gateway.

### Setting Up a Project

1. Create `.claude/infra/.mcp.json` in your project root with your MCP servers:

```json
{
  "mcpServers": {
    "my-server": {
      "command": "npx",
      "args": ["-y", "@my/mcp-server"],
      "env": { "API_KEY": "..." }
    }
  }
}
```

2. Open MCPHub from the menu bar and click **Add Project**
3. Select your project folder
4. Click **Scan Tools** to discover available tools
5. Toggle servers and tools as needed
6. Click **Apply & Restart** to apply changes to Claude Desktop

## Roadmap

- **MCP Marketplace** — browse and install MCP servers from a community registry
- **Per-project profiles** — save and load different server/tool configurations
- **Tool usage analytics** — track which tools Claude uses most
- **Multi-app support** — manage MCP configs for apps beyond Claude Desktop
- **Health monitoring** — auto-detect crashed servers and reconnect
- **Config sync** — sync configurations across machines
- **Native gateway** — rewrite the gateway in Swift to drop the Node.js dependency

## License

[MIT](LICENSE)
