# Claude Hub

Native macOS app for per-project MCP server management in [Claude Desktop](https://claude.ai/download).

Claude Desktop uses a single global MCP config. Claude Hub lets each project define its own servers, tools, and secrets.

## How it works

Each project keeps its MCP config under `.claude/infra/`:

```
your-project/
├── .claude/
│   └── infra/
│       ├── .mcp.json            # MCP server definitions (you edit this)
│       ├── .env                 # secrets, loaded as env vars per server
│       └── gateway.config.json  # generated — tracks enabled state + discovered tools
└── .mcp.json                    # generated — points Claude Desktop at the gateway
```

A Node.js gateway process sits between Claude Desktop and your MCP servers. It reads the config, connects to each enabled server, and exposes only the tools you've turned on. Claude Desktop talks to one gateway endpoint instead of N servers.

You can toggle individual tools per server (not just whole servers).

## Prerequisites

- macOS 14+
- Node.js 18+
- Swift 5.10+ (Xcode 15+)
- Claude Desktop

## Install

```bash
git clone https://github.com/marks97/mcp-hub.git
cd mcp-hub
./install.sh
```

This builds the app, copies it to `/Applications/ClaudeHub.app`, and registers a LaunchAgent for login startup.

## Usage

1. Click **+** in the toolbar to add a project (must contain `.claude/infra/.mcp.json`)
2. Click the **refresh** icon to discover tools from each server
3. Toggle servers and tools on/off
4. Click the **Claude status** indicator to start or restart Claude Desktop

## License

[MIT](LICENSE)
