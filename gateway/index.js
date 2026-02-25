import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { StdioClientTransport } from "@modelcontextprotocol/sdk/client/stdio.js";
import { readFileSync } from "fs";
import { resolve } from "path";

const CONFIG_PATH = process.env.MCP_GATEWAY_CONFIG;
if (!CONFIG_PATH) {
  process.stderr.write("MCP_GATEWAY_CONFIG env var required\n");
  process.exit(1);
}

const config = JSON.parse(readFileSync(resolve(CONFIG_PATH), "utf-8"));
const upstreams = new Map();

async function connectUpstream(name, serverConfig) {
  const client = new Client({ name: `gateway->${name}`, version: "1.0.0" });
  const transport = new StdioClientTransport({
    command: serverConfig.command,
    args: serverConfig.args || [],
    env: { ...process.env, ...(serverConfig.env || {}) },
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

  upstreams.set(name, { client, tools: allowedTools });
  process.stderr.write(
    `[${name}] connected: ${allowedTools.length}/${tools.length} tools\n`
  );

  return allowedTools.map((t) => ({ ...t, _upstream: name }));
}

async function main() {
  const gateway = new McpServer(
    { name: "mcp-gateway", version: "1.0.0" },
    { capabilities: { tools: {} } }
  );

  const registeredTools = new Map();
  let toolCount = 0;

  for (const [name, serverConfig] of Object.entries(config.servers)) {
    if (!serverConfig.enabled) continue;
    try {
      const tools = await connectUpstream(name, serverConfig);
      for (const tool of tools) {
        const upstreamName = tool._upstream;

        if (registeredTools.has(tool.name)) {
          process.stderr.write(
            `[warning] tool "${tool.name}" from "${upstreamName}" ` +
              `conflicts with "${registeredTools.get(tool.name)}", skipping\n`
          );
          continue;
        }
        registeredTools.set(tool.name, upstreamName);

        const schema = tool.inputSchema || { type: "object", properties: {} };

        // The MCP SDK's tool() expects a Zod-like schema where each property
        // is { type: "string", description }. This flattens all property types
        // to strings — upstream servers must handle type coercion.
        const proxySchema = {};
        if (schema.properties) {
          for (const [key, prop] of Object.entries(schema.properties)) {
            proxySchema[key] = {
              type: "string",
              description: prop.description || "",
            };
          }
        }

        const validKeys = new Set(Object.keys(schema.properties || {}));

        gateway.tool(
          tool.name,
          tool.description || "",
          proxySchema,
          async (args) => {
            const upstream = upstreams.get(upstreamName);
            const cleanArgs = {};
            for (const [k, v] of Object.entries(args)) {
              if (validKeys.has(k)) cleanArgs[k] = v;
            }
            try {
              const result = await upstream.client.callTool({
                name: tool.name,
                arguments: cleanArgs,
              });
              return result;
            } catch (err) {
              return {
                content: [
                  { type: "text", text: `[${upstreamName}] ${err.message}` },
                ],
                isError: true,
              };
            }
          }
        );

        toolCount++;
      }
    } catch (err) {
      process.stderr.write(`[${name}] failed to connect: ${err.message}\n`);
    }
  }

  const transport = new StdioServerTransport();
  await gateway.connect(transport);
  process.stderr.write(
    `Gateway ready: ${toolCount} tools from ${upstreams.size} servers\n`
  );
}

main().catch((err) => {
  process.stderr.write(`Gateway fatal: ${err.message}\n`);
  process.exit(1);
});
