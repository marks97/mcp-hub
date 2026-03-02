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

### Project isolation

When enabled in Settings (Cmd+,), each project runs its own Claude Desktop instance in an isolated Electron data directory at `~/claude-{project-name}`. This gives each project a separate config, window state, and process — multiple projects can run Claude simultaneously without interfering with each other.

Claude is launched with `--user-data-dir=~/claude-{project-name}`, so keychain and auth tokens from your real HOME still work.

Off by default. When off, a single shared Claude Desktop instance is used.

### MCP Marketplace

Browse and install servers from the [official MCP registry](https://registry.modelcontextprotocol.io). Click **Marketplace** in the project detail header to search for servers. Supports npm, PyPI, and Docker packages. You can also add servers manually via the **Add Server** button.

## Prerequisites

- macOS 14+
- Node.js 18+
- Swift 5.10+ (Xcode 15+)
- Claude Desktop

## Install

```bash
git clone https://github.com/marks97/claude-hub.git
cd claude-hub
./install.sh
```

This builds the app, copies it to `/Applications/ClaudeHub.app`, and registers a LaunchAgent for login startup.

## Usage

1. Click **+** in the toolbar to add a project (or any folder — `.claude/infra/` is scaffolded automatically)
2. Click the **refresh** icon to discover tools from each server
3. Toggle servers and tools on/off
4. Click the **Claude status** indicator to start or restart Claude Desktop
5. Use **Add Server** or **Marketplace** to add new MCP servers
6. Hover over a project in the sidebar to remove it
7. Open **Settings** (Cmd+,) to enable project isolation or manage marketplace sources

## License

[MIT](LICENSE)
