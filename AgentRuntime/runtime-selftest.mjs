import { createServer } from "node:http";
import { createAgentSession, ModelRuntime, SessionManager, SettingsManager } from "@earendil-works/pi-coding-agent";
import { Type } from "typebox";
import { randomBytes } from "node:crypto";

// Exercises the installed SDK with an ephemeral loopback model, never a user provider.
export async function runtimeSelfTest(loader) {
  let calls = 0;
  let toolExecuted = false;
  let streamed = "";
  let session;
  const token = randomBytes(32).toString("hex");
  const server = createServer(async (request, response) => {
    if (request.method !== "POST" || request.url !== "/v1/chat/completions" || request.headers.authorization !== `Bearer ${token}`) {
      response.writeHead(403).end(); return;
    }
    let body = "";
    for await (const part of request) {
      body += part;
      if (body.length > 256000) { response.writeHead(413).end(); return; }
    }
    let payload;
    try { payload = JSON.parse(body); } catch { response.writeHead(400).end(); return; }
    if (!Array.isArray(payload.messages)) { response.writeHead(400).end(); return; }
    calls++;
    response.writeHead(200, { "content-type": "text/event-stream" });
    const send = (delta, finish) => response.write(`data: ${JSON.stringify({ id: "selftest", object: "chat.completion.chunk", created: 1, model: "selftest",
      choices: [{ index: 0, delta, finish_reason: finish }] })}\n\n`);
    if (payload.messages.some(message => message.role === "tool")) {
      send({ role: "assistant", content: "OK" }, null);
      send({}, "stop");
    } else {
      send({ role: "assistant", tool_calls: [{ index: 0, id: "selftest-call", type: "function",
        function: { name: "health_echo", arguments: '{"value":"ping"}' } }] }, null);
      send({}, "tool_calls");
    }
    response.end("data: [DONE]\n\n");
  });
  await new Promise((resolve, reject) => {
    server.once("error", reject);
    server.listen(0, "127.0.0.1", resolve);
  });
  const credentials = { async read() {}, async list() { return []; }, async modify() { throw new Error("unavailable"); }, async delete() {} };
  let timer;
  try {
    const runtime = await ModelRuntime.create({ credentials, modelsPath: null, allowModelNetwork: false, refreshOnCreate: false });
    runtime.registerProvider("trendingtab-selftest", { baseUrl: `http://127.0.0.1:${server.address().port}/v1`,
      api: "openai-completions", apiKey: "runtime-key", models: [{ id: "selftest", name: "selftest", reasoning: false,
        input: ["text"], contextWindow: 4096, maxTokens: 100, cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 } }] });
    await runtime.setRuntimeApiKey("trendingtab-selftest", token);
    const model = runtime.getModel("trendingtab-selftest", "selftest");
    if (!model) throw new Error("Self-test model unavailable");
    ({ session } = await createAgentSession({ cwd: process.cwd(), agentDir: process.cwd(), modelRuntime: runtime, model,
      resourceLoader: loader("Self-test"), sessionManager: SessionManager.inMemory(),
      settingsManager: SettingsManager.inMemory({ compaction: { enabled: false }, retry: { enabled: false } }),
      tools: ["health_echo"], customTools: [{ name: "health_echo", label: "Health", description: "Echo ping",
        parameters: Type.Object({ value: Type.String() }),
        async execute(_id, args) { toolExecuted = args.value === "ping"; return { content: [{ type: "text", text: args.value }], details: {} }; } }] }));
    const unsubscribe = session.subscribe(event => {
      if (event.type === "message_update" && event.assistantMessageEvent.type === "text_delta") streamed += event.assistantMessageEvent.delta;
    });
    try {
      await Promise.race([session.prompt("Call health_echo with ping and respond OK."), new Promise((_, reject) => {
        timer = setTimeout(() => { void session.abort(); reject(new Error("Self-test timed out")); }, 8000);
      })]);
    } finally { unsubscribe(); }
    if (!toolExecuted || calls !== 2 || streamed !== "OK") throw new Error("Self-test result invalid");
    return { protocol: 1, streaming: true, tools: true };
  } finally {
    clearTimeout(timer);
    session?.dispose();
    server.closeAllConnections();
    await new Promise(resolve => server.close(resolve));
  }
}
