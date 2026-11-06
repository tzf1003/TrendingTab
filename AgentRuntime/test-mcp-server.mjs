import { createInterface } from "node:readline";

const server = createInterface({ input: process.stdin });
for await (const line of server) {
  const request = JSON.parse(line);
  if (request.id == null) continue;
  let result;
  if (request.method === "initialize") {
    if (process.env.DELAY_INITIALIZE) await new Promise(resolve => setTimeout(resolve, 3000));
    result = { protocolVersion: "2025-11-25", capabilities: { tools: {} }, serverInfo: { name: "fixture", version: "1" } };
  }
  else if (request.method === "tools/list") result = { tools: [
    { name: "echo", inputSchema: { type: "object" }, annotations: { readOnlyHint: true } },
    { name: "disabled", inputSchema: { type: "object" } },
  ] };
  else if (request.method === "tools/call") {
    if (request.params.arguments.wait) continue;
    result = { content: [{ type: "text", text: JSON.stringify({ arguments: request.params.arguments,
      fixture: process.env.FIXTURE, inherited: process.env.TRENDINGTAB_PRIVATE_TEST ?? null }) }] };
  } else result = {};
  process.stdout.write(JSON.stringify({ jsonrpc: "2.0", id: request.id, result }) + "\n");
}
