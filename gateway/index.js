import { Server } from "@modelcontextprotocol/sdk/server/index.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { StdioClientTransport } from "@modelcontextprotocol/sdk/client/stdio.js";
import {
  ListToolsRequestSchema,
  CallToolRequestSchema,
} from "@modelcontextprotocol/sdk/types.js";
import { readFileSync } from "fs";
import { resolve, dirname } from "path";

const CONFIG_PATH = process.env.MCP_GATEWAY_CONFIG;
if (!CONFIG_PATH) {
  process.stderr.write("MCP_GATEWAY_CONFIG env var required\n");
  process.exit(1);
}

// Optional: only connect to a single named server from the config
const SERVER_FILTER = process.env.MCP_GATEWAY_SERVER;

const resolvedConfigPath = resolve(CONFIG_PATH);
const config = JSON.parse(readFileSync(resolvedConfigPath, "utf-8"));

// Derive project root from config path (always at .claude/infra/gateway.config.json)
const projectRoot = resolve(dirname(resolvedConfigPath), "../..");

// Ensure node's bin directory is in PATH for upstream processes
// (GUI apps like Claude Desktop launch us with minimal PATH)
const nodeBin = dirname(process.execPath);
if (!process.env.PATH?.includes(nodeBin)) {
  process.env.PATH = `${nodeBin}:${process.env.PATH || ""}`;
}

const allTools = [];
const toolToUpstream = new Map();
const upstreamClients = new Map();

function sanitizeAnnotations(annotations) {
  if (!annotations || typeof annotations !== "object") return undefined;
  const clean = {};
  for (const [key, value] of Object.entries(annotations)) {
    if (typeof value === "string" || typeof value === "boolean") {
      clean[key] = value;
    } else if (value !== null && value !== undefined) {
      clean[key] = String(value);
    }
  }
  return Object.keys(clean).length > 0 ? clean : undefined;
}

async function connectUpstream(name, serverConfig) {
  const client = new Client({ name: `gateway->${name}`, version: "1.0.0" });
  const transport = new StdioClientTransport({
    command: serverConfig.command,
    args: serverConfig.args || [],
    env: { ...process.env, ...(serverConfig.env || {}) },
    cwd: projectRoot,
    stderr: "pipe",
  });

  transport.onerror = (err) => {
    process.stderr.write(`[${name}] transport error: ${err.message}\n`);
  };

  await client.connect(transport);
  const { tools } = await client.listTools();

  const allowedTools =
    serverConfig.tools === "*"
      ? tools
      : tools.filter((t) => serverConfig.tools.includes(t.name));

  upstreamClients.set(name, client);

  for (const tool of allowedTools) {
    if (toolToUpstream.has(tool.name)) {
      process.stderr.write(
        `[warning] tool "${tool.name}" from "${name}" conflicts with "${toolToUpstream.get(tool.name)}", skipping\n`
      );
      continue;
    }
    toolToUpstream.set(tool.name, name);

    const sanitized = { ...tool };
    if (sanitized.annotations) {
      sanitized.annotations = sanitizeAnnotations(sanitized.annotations);
    }
    delete sanitized._upstream;
    allTools.push(sanitized);
  }

  process.stderr.write(
    `[${name}] connected: ${allowedTools.length}/${tools.length} tools\n`
  );
}

async function main() {
  const server = new Server(
    { name: "mcp-gateway", version: "1.0.0" },
    { capabilities: { tools: {} } }
  );

  server.setRequestHandler(ListToolsRequestSchema, async () => ({
    tools: allTools,
  }));

  server.setRequestHandler(CallToolRequestSchema, async (request) => {
    const { name, arguments: args } = request.params;
    const upstreamName = toolToUpstream.get(name);

    if (!upstreamName) {
      return {
        content: [{ type: "text", text: `Unknown tool: ${name}` }],
        isError: true,
      };
    }

    const client = upstreamClients.get(upstreamName);
    try {
      const result = await client.callTool({ name, arguments: args || {} });
      return result;
    } catch (err) {
      return {
        content: [
          { type: "text", text: `[${upstreamName}] ${err.message}` },
        ],
        isError: true,
      };
    }
  });

  for (const [name, serverConfig] of Object.entries(config.servers)) {
    if (!serverConfig.enabled) continue;
    if (SERVER_FILTER && name !== SERVER_FILTER) continue;
    try {
      await connectUpstream(name, serverConfig);
    } catch (err) {
      process.stderr.write(`[${name}] failed to connect: ${err.message}\n`);
    }
  }

  process.stderr.write(
    `Gateway ready: ${allTools.length} tools from ${upstreamClients.size} servers\n`
  );

  const transport = new StdioServerTransport();
  await server.connect(transport);
}

main().catch((err) => {
  process.stderr.write(`Gateway fatal: ${err.message}\n`);
  process.exit(1);
});
