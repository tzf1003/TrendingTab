import test from "node:test";
import assert from "node:assert/strict";
import { createServer } from "node:http";
import { fileURLToPath } from "node:url";
import { ManagedMcpConnection } from "./mcp-client.mjs";

const serverFile = fileURLToPath(new URL("./test-mcp-server.mjs", import.meta.url));
const config = { type: "stdio", command: process.execPath, args: [serverFile], env: { FIXTURE: "$literal!" } };

test("stdio isolates environment and requires enabled tool and per-call permission", async () => {
  process.env.TRENDINGTAB_PRIVATE_TEST = "must-not-be-inherited";
  const decisions = [];
  const connection = new ManagedMcpConnection(config, ["echo"], async request => {
    decisions.push(request.name); return request.arguments.allow === true;
  });
  try {
    assert.deepEqual((await connection.connect()).map(tool => tool.name), ["echo"]);
    await assert.rejects(connection.call("disabled", {}, { runID: "run" }), /unavailable/);
    await assert.rejects(connection.call("echo", { allow: false }, { runID: "run" }), /permission denied/);
    const result = await connection.call("echo", { allow: true }, { runID: "run" });
    assert.deepEqual(JSON.parse(result.content[0].text), { arguments: { allow: true }, fixture: "$literal!", inherited: null });
    assert.deepEqual(decisions, ["echo", "echo"]);
  } finally { await connection.close(); delete process.env.TRENDINGTAB_PRIVATE_TEST; }
  await assert.rejects(connection.call("echo", {}, { runID: "run" }), /unavailable/);
});

test("cancellation while awaiting authorization and in flight stops the call", async () => {
  let resolvePermission;
  const connection = new ManagedMcpConnection(config, ["echo"], request => request.arguments.waitForPermission
    ? new Promise(resolve => { resolvePermission = resolve; }) : true);
  try {
    await connection.connect();
    const controller = new AbortController();
    const pending = connection.call("echo", { waitForPermission: true }, { runID: "run", signal: controller.signal });
    controller.abort();
    await assert.rejects(pending, { name: "AbortError" });
    resolvePermission(true);
    const second = new AbortController();
    const running = connection.call("echo", { wait: true }, { runID: "run", signal: second.signal });
    setTimeout(() => second.abort(), 30);
    await assert.rejects(running);
  } finally { await connection.close(); }
});

test("the approved request is isolated from later mutations and closing cancels authorization", async () => {
  let resolvePermission;
  const connection = new ManagedMcpConnection(config, ["echo"], request => {
    request.arguments.value = "changed by approval UI";
    return new Promise(resolve => { resolvePermission = resolve; });
  });
  await connection.connect();
  const argumentsObject = { value: "original" };
  const pending = connection.call("echo", argumentsObject, { runID: "run" });
  argumentsObject.value = "changed by caller";
  resolvePermission(true);
  const result = await pending;
  assert.equal(JSON.parse(result.content[0].text).arguments.value, "original");
  const closing = connection.call("echo", {}, { runID: "run" });
  const rejected = assert.rejects(closing, { name: "AbortError" });
  await connection.close();
  await rejected;
  resolvePermission(true);
});

test("HTTP connection keeps credentials on the configured origin and rejects redirects", async () => {
  assert.throws(() => new ManagedMcpConnection({ type: "http", url: "https://example.test", headers: { Cookie: "session=secret" } }, [], () => true), /Invalid MCP HTTP/);
  assert.throws(() => new ManagedMcpConnection({ type: "http", url: "https://example.test", headers: { Authorization: "one", authorization: "two" } }, [], () => true), /Invalid MCP HTTP/);
  let redirects = 0;
  const server = createServer(async (request, response) => {
    if (request.url === "/redirect") { redirects++; response.writeHead(302, { location: "/mcp" }); response.end(); return; }
    assert.equal(request.headers.authorization, "Bearer $literal!");
    let body = "";
    for await (const chunk of request) body += chunk;
    const message = body ? JSON.parse(body) : {};
    if (message.id == null) { response.writeHead(202); response.end(); return; }
    let result = {};
    if (message.method === "initialize") result = { protocolVersion: "2025-11-25", capabilities: { tools: {} }, serverInfo: { name: "fixture", version: "1" } };
    if (message.method === "tools/list") result = { tools: [{ name: "echo", inputSchema: { type: "object" } }] };
    if (message.method === "tools/call") result = { content: [{ type: "text", text: "ok" }] };
    response.writeHead(200, { "content-type": "application/json" });
    response.end(JSON.stringify({ jsonrpc: "2.0", id: message.id, result }));
  });
  await new Promise(resolve => server.listen(0, "127.0.0.1", resolve));
  const base = `http://127.0.0.1:${server.address().port}`;
  const connection = new ManagedMcpConnection({ type: "http", url: base + "/mcp", headers: { Authorization: "Bearer $literal!" } }, ["echo"], () => true);
  try {
    await connection.connect();
    assert.equal((await connection.call("echo", {}, { runID: "run" })).content[0].text, "ok");
    const redirected = new ManagedMcpConnection({ type: "http", url: base + "/redirect" }, [], () => true);
    await assert.rejects(redirected.connect());
    assert.equal(redirects, 1);
  } finally { await connection.close(); await new Promise(resolve => server.close(resolve)); }
});
