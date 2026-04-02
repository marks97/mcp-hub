# Claude Hub

Native macOS app for managing MCP servers, tools, and Claude Desktop instances per project.

![Claude Hub](assets/screenshot.png)

## Why

Claude Desktop uses one global MCP config. If you work on multiple projects with different servers and secrets, you're constantly editing that file. Claude Hub fixes that — each project gets its own servers, secrets, and tool toggles.

## Features

**Per-project MCP management** — Each project has its own servers, env vars (`.env`), and tool-level toggles. A per-server gateway proxies each MCP server independently. Servers are written to `.mcp.json` at the project root and synced to `claude_desktop_config.json` for isolated instances. You can enable/disable individual tools, not just whole servers.

**Per-project Claude Desktop isolation** — Run separate Claude Desktop instances per project. Multiple projects can have Claude running simultaneously. Each isolated instance appears in the Dock with its own name (just the project name by default — configurable prefix/suffix in Settings). Launch shared or isolated from the toolbar menu.

**Bidirectional sync** — Server enable/disable state syncs between Claude Hub and Claude Desktop. Changes in either direction are detected via polling and reflected in both UIs.

**MCP Marketplace** — Browse the [official MCP registry](https://registry.modelcontextprotocol.io), search by category, and add servers with pre-filled commands. Supports npm, PyPI, and Docker packages.

## Install

```bash
git clone https://github.com/marks97/claude-hub.git
cd claude-hub
./install.sh
```

Requires macOS 14+, Node.js 18+, Swift 5.10+, and [Claude Desktop](https://claude.ai/download).

## License

[MIT](LICENSE)
