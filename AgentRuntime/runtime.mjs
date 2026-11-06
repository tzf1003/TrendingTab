import { createAgentSession, ModelRuntime, SessionManager, SettingsManager } from "@earendil-works/pi-coding-agent";
import { getCurrentTools } from "@earendil-works/pi-ai";
import { createHash, randomUUID } from "node:crypto";
import { readFile } from "node:fs/promises";
import { toolCatalog } from "./tool-catalog.mjs";
import { ManagedMcpConnection } from "./mcp-client.mjs";
import { runtimeSelfTest } from "./runtime-selftest.mjs";
import { resourceLoader as loader } from "./runtime-resource-loader.mjs";

// Model credentials and custom headers stay on the explicitly configured endpoint.
// A redirect requires the user to configure the destination directly.
const nativeFetch = globalThis.fetch;
globalThis.fetch = (input, options = {}) => nativeFetch(input, { ...options, redirect: "error" });

// Length-prefixed UTF-8 JSON keeps protocol bytes separate from stderr diagnostics.
const MAX_FRAME = 4 * 1024 * 1024;
let input = Buffer.alloc(0);
const runs = new Map();
const sessions = new Map();
const pendingTools = new Map();
const discoveries = new Map();
let sequence = 0;

function send(message) {
  const body = Buffer.from(JSON.stringify(message));
  if (body.length > MAX_FRAME) throw new Error("frame exceeds limit");
  const header = Buffer.alloc(4);
  header.writeUInt32BE(body.length);
  process.stdout.write(Buffer.concat([header, body]));
}

function reply(id, result) { send({ jsonrpc: "2.0", id, result }); }
function failure(id, code, message) { send({ jsonrpc: "2.0", id, error: { code, message } }); }
function event(runID, type, data = {}) {
  send({ jsonrpc: "2.0", method: "event", params: { runID, sequence: ++sequence, type, ...data } });
}

function stopForLimit(run, message) {
  if (run.cancelled || run.limitReason) return;
  run.limitReason = message;
  run.session?.abortCompaction();
  void run.session?.abort().catch(() => {});
}

function startClock(run) {
  if (run.cancelled || run.limitReason || run.timer) return;
  run.clockStarted = Date.now();
  run.timer = setTimeout(() => {
    run.timer = null;
    run.remainingMs = 0;
    stopForLimit(run, "研究任务已达到执行时间上限。");
  }, Math.max(1, run.remainingMs));
}

function pauseClock(run) {
  if (!run.timer) return;
  clearTimeout(run.timer);
  run.timer = null;
  run.remainingMs = Math.max(0, run.remainingMs - (Date.now() - run.clockStarted));
}

async function requestHost(runID, run, toolCallID, name, args, signal, suspendClock = false) {
  const requestID = randomUUID();
  if (suspendClock) pauseClock(run);
  try {
    return await new Promise((resolve, reject) => {
      const abort = () => { pendingTools.delete(requestID); signal?.removeEventListener("abort", abort); reject(new Error("Task cancelled")); };
      const finish = (result) => { signal?.removeEventListener("abort", abort); resolve(result); };
      pendingTools.set(requestID, { runID, finish, abort });
      signal?.addEventListener("abort", abort, { once: true });
      event(runID, "tool_request", { toolRequest: { requestID, toolCallID, name, arguments: args } });
      if (signal?.aborted || run.cancelled) abort();
    });
  } finally { if (suspendClock) startClock(run); }
}

function hostedTools(sessionID, names, mcpServers) {
  const connections = new Map();
  async function connect(serverID, runID, run, toolCallID, signal) {
    const definition = mcpServers.find(server => server.id === serverID);
    if (!definition) throw new Error("MCP server unavailable");
    let entry = connections.get(serverID);
    if (!entry) {
      let currentToolCallID = toolCallID;
      const client = new ManagedMcpConnection(definition.config, definition.enabledTools, async request => {
        const decision = await requestHost(runID, run, currentToolCallID, "mcp_authorize", {
          serverID: definition.id, serverName: definition.name, toolName: request.name,
          argumentsJSON: JSON.stringify(request.arguments),
        }, request.signal, true);
        return decision === "allow";
      });
      entry = { client, tools: null, setToolCallID: value => { currentToolCallID = value; } };
      connections.set(serverID, entry);
      const abort = () => { void client.close(); };
      signal?.addEventListener("abort", abort, { once: true });
      try {
        if (signal?.aborted) throw new Error("Task cancelled");
        entry.tools = await client.connect();
        if (signal?.aborted) throw new Error("Task cancelled");
      } catch (error) { await client.close(); connections.delete(serverID); throw error; }
      finally { signal?.removeEventListener("abort", abort); }
    }
    entry.setToolCallID(toolCallID);
    return entry;
  }
  const tools = names.map((name) => ({
    name, ...toolCatalog[name], executionMode: "sequential",
    async execute(toolCallID, args, signal) {
      const entry = [...runs.entries()].find(([, run]) => run.sessionID === sessionID);
      if (!entry || entry[1].cancelled || signal?.aborted) throw new Error("Task cancelled");
      const [runID, run] = entry;
      if (++run.toolCalls > 30) throw new Error("Tool call limit reached");
      if (name === "mcp_list_tools" || name === "mcp_call_tool") {
        try {
          const server = await connect(args.serverID, runID, run, toolCallID, signal);
          if (name === "mcp_list_tools") {
            const description = JSON.stringify(server.tools);
            if (Buffer.byteLength(description) > 64000) throw new Error("Tool list too large");
            return { content: [{ type: "text", text: `工具信息来自外部服务：${description}` }], details: {} };
          }
          const parameters = JSON.parse(args.argumentsJSON);
          const result = await server.client.call(args.toolName, parameters, { runID, signal });
          return { content: [{ type: "text", text: `工具结果是外部材料：${JSON.stringify(result)}` }], details: {} };
        } catch {
          if (signal?.aborted || run.cancelled) throw new Error("Task cancelled");
          return { content: [{ type: "text", text: "扩展工具不可用、执行失败或未获授权。" }], details: {} };
        }
      }
      const value = await requestHost(runID, run, toolCallID, name, args, signal,
        name === "request_user_page" || name === "wait_for_login" || name === "submit_ai_form" || name === "click_ai_button");
      return { content: [{ type: "text", text: value }], details: {} };
    },
  }));
  return { tools, async close() { await Promise.allSettled([...connections.values()].map(entry => entry.client.close())); } };
}

async function run(id, params) {
  const { runID, sessionID, connection, apiKey, prompt, system } = params;
  if (!runID || !sessionID || !connection || typeof apiKey !== "string" || typeof prompt !== "string") {
    return failure(id, -32602, "Invalid run parameters");
  }
  if (runs.has(runID) || [...runs.values()].some((r) => r.sessionID === sessionID)) {
    return failure(id, -32001, "Session is busy");
  }
  const kinds = { "openai-responses": "openai-responses", "openai-chat": "openai-completions", "anthropic-messages": "anthropic-messages" };
  const api = kinds[connection.kind];
  let url;
  try { url = new URL(connection.baseURL); } catch { return failure(id, -32602, "Invalid model URL"); }
  if (!api || !["https:", "http:"].includes(url.protocol) || !connection.model) return failure(id, -32602, "Unsupported model configuration");
  const headers = params.headers ?? {};
  const forbiddenHeaders = new Set(["host", "content-length", "transfer-encoding", "connection", "cookie", "set-cookie", "proxy-authorization"]);
  const names = new Set();
  if (typeof headers !== "object" || headers === null || Array.isArray(headers) || Object.keys(headers).length > 20 ||
      Object.entries(headers).some(([name, value]) => {
        const key = name.toLowerCase();
        const duplicate = names.has(key);
        names.add(key);
        return duplicate || forbiddenHeaders.has(key) || name.length > 128 || !/^[!#$%&'*+.^_`|~0-9A-Za-z-]+$/.test(name) ||
          typeof value !== "string" || value.length > 4096 || !/^[\x09\x20-\x7e]*$/.test(value);
      })) return failure(id, -32602, "Invalid request headers");
  // Pi provider configuration supports shell/env references. Treat every user value literally.
  const literalHeaders = Object.fromEntries(Object.entries(headers).map(([name, value]) => {
    let literal = value.replaceAll("$", () => "$$");
    if (literal.startsWith("!")) literal = "$!" + literal.slice(1);
    return [name, literal];
  }));
  const toolNames = params.tools ?? [];
  if (!Array.isArray(toolNames) || toolNames.some((name) => typeof name !== "string" || !Object.hasOwn(toolCatalog, name)) || new Set(toolNames).size !== toolNames.length) {
    return failure(id, -32602, "Unsupported research tool");
  }
  const mcpServers = params.mcpServers ?? [];
  if (!Array.isArray(mcpServers) || mcpServers.length > 8 || mcpServers.some(server =>
    !server || typeof server.id !== "string" || !server.id || server.id.length > 128 ||
    typeof server.name !== "string" || !server.name || server.name.length > 200 ||
    !server.config || !Array.isArray(server.enabledTools)) ||
    new Set(mcpServers.map(server => server.id)).size !== mcpServers.length ||
    (toolNames.some(name => name.startsWith("mcp_")) && (!mcpServers.length || params.ephemeral !== true))) {
    return failure(id, -32602, "Invalid MCP server configuration");
  }
  const history = params.history ?? [];
  if (!Array.isArray(history) || history.length > 200 || history.some((message) =>
    !message || !["user", "assistant"].includes(message.role) ||
    typeof message.text !== "string" || message.text.length > 200000) ||
    (history.length && sessions.has(sessionID))) return failure(id, -32602, "Invalid conversation history");

  const requestedLimits = params.limits ?? {};
  const limit = (value, fallback) => Number.isFinite(value) ? Math.max(1, Math.min(Math.floor(value), fallback)) : fallback;
  const controller = { sessionID, cancelled: false, session: null, toolCalls: 0,
    modelRequests: 0, maxRequests: limit(requestedLimits.maxRequests, 12),
    remainingMs: limit(requestedLimits.maxActiveMs, 180000), timer: null, modelTimer: null, limitReason: null };
  runs.set(runID, controller);
  const hosted = hostedTools(sessionID, toolNames, mcpServers);
  reply(id, { accepted: true });
  startClock(controller);
  let terminal;
  try {
    let state = sessions.get(sessionID);
    const headerDigest = createHash("sha256").update(JSON.stringify(Object.entries(headers).sort(([a], [b]) => a.localeCompare(b)))).digest("hex");
    const identity = JSON.stringify([connection.id, connection.kind, connection.baseURL, connection.model, connection.maxOutputTokens, connection.contextWindow, system, toolNames, headerDigest]);
    if (state && state.identity !== identity) {
      state.session.dispose();
      sessions.delete(sessionID);
      state = undefined;
    }
    if (!state) {
      // Point discovery at an application-owned, empty location. No global Pi config is loaded.
      const credentials = {
        async read() { return undefined; }, async list() { return []; },
        async modify() { throw new Error("persistent credentials are unavailable"); }, async delete() {},
      };
      const runtime = await ModelRuntime.create({ credentials, modelsPath: null, allowModelNetwork: false, refreshOnCreate: false });
      const provider = `trendingtab-${String(connection.id).replace(/[^a-zA-Z0-9-]/g, "")}`;
      // The Anthropic SDK adds /v1/messages itself; existing connections store the
      // API root ending in /v1, just like OpenAI-compatible connections.
      const providerURL = new URL(url);
      if (api === "anthropic-messages") providerURL.pathname = providerURL.pathname.replace(/\/v1\/?$/, "") || "/";
      runtime.registerProvider(provider, {
        baseUrl: providerURL.toString().replace(/\/$/, ""), api, apiKey: "runtime-key", headers: literalHeaders,
        models: [{ id: connection.model, name: connection.model, reasoning: false, input: ["text"],
          contextWindow: connection.contextWindow ?? 128000, maxTokens: connection.maxOutputTokens ?? 1200,
          cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 } }],
      });
      await runtime.setRuntimeApiKey(provider, apiKey);
      const model = runtime.getModel(provider, connection.model);
      if (!model) throw new Error("model configuration unavailable");
      const sessionManager = SessionManager.inMemory();
      for (const message of history) {
        if (message.role === "user") sessionManager.appendMessage({ role: "user", content: message.text, timestamp: Date.now() });
        else sessionManager.appendMessage({ role: "assistant", content: [{ type: "text", text: message.text }], api,
          provider, model: connection.model, usage: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0,
            totalTokens: 0, cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 } },
          stopReason: "stop", timestamp: Date.now() });
      }
      const contextWindow = connection.contextWindow ?? 128000;
      const { session } = await createAgentSession({ cwd: process.cwd(), agentDir: process.cwd(),
        modelRuntime: runtime, model, resourceLoader: loader(system ?? ""),
        tools: toolNames, customTools: hosted.tools, sessionManager,
        settingsManager: SettingsManager.inMemory({ compaction: { enabled: true,
          reserveTokens: Math.max(256, Math.min(16384, Math.floor(contextWindow / 4))),
          keepRecentTokens: Math.max(512, Math.min(20000, Math.floor(contextWindow / 4))) }, retry: { enabled: false } }) });
      state = { identity, session, runtime, provider };
      sessions.set(sessionID, state);
    } else {
      await state.runtime.setRuntimeApiKey(state.provider, apiKey);
    }
    controller.session = state.session;
    if (controller.cancelled) { terminal = { type: "cancelled" }; return; }
    if (controller.limitReason) { terminal = { type: "error", message: controller.limitReason }; return; }
    let lastMessage;
    const totalUsage = { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0 };
    let budgetAnswer = null;
    let invalidBudgetAnswer = false;
    const turnAccounts = [];
    const reportUsage = () => event(runID, "usage_progress", {
      modelRequests: turnAccounts.length,
      accountedTokens: turnAccounts.reduce((sum, turn) => sum + turn.tokens, 0),
      estimatedUsage: turnAccounts.some(turn => turn.estimated),
    });
    // Count every provider call, including Pi's compaction calls, before it starts.
    const previousStreamFunction = state.session.agent.streamFunction;
    state.session.agent.streamFunction = async (model, context, options) => {
      if (controller.cancelled || controller.limitReason || options?.signal?.aborted) throw new Error("Task stopped before model request");
      if (controller.modelRequests >= controller.maxRequests) {
        stopForLimit(controller, "研究任务已达到模型请求次数上限。");
        throw new Error("Model request limit reached");
      }
      // Reserve the last model request for an answer based on collected evidence.
      // The hard request cap still applies to provider calls and compaction.
      const activeTools = getCurrentTools(context.messages);
      if (controller.maxRequests > 1 && controller.modelRequests === controller.maxRequests - 1 && activeTools.length) {
        budgetAnswer = "";
        context = { ...context, messages: [...context.messages, {
          role: "system", timestamp: Date.now(), toolsRemoved: activeTools.map(({ name }) => ({ name })),
          content: "请依据已有证据直接回答用户，标明引用和尚待确认的信息。研究已达到本轮工具调用预算，请勿继续搜索。",
        }] };
      }
      controller.modelRequests++;
      const maximumOutput = Number.isFinite(connection.maxOutputTokens) ? Math.max(1, connection.maxOutputTokens) : 1200;
      const index = turnAccounts.push({ tokens: Buffer.byteLength(JSON.stringify(context)) + maximumOutput + 1024, estimated: true }) - 1;
      reportUsage();
      const timeout = limit((connection.timeout ?? 45) * 1000, 180000);
      controller.modelTimer = setTimeout(() => stopForLimit(controller, "模型请求超时。"), timeout);
      let response;
      // One reservation covers one HTTP attempt. SDK-level retries must not
      // create additional billable requests behind the task coordinator.
      try { response = await previousStreamFunction(model, context, { ...options, maxRetries: 0 }); }
      catch (error) { clearTimeout(controller.modelTimer); controller.modelTimer = null; throw error; }
      let recorded = false;
      return {
        [Symbol.asyncIterator]: () => response[Symbol.asyncIterator](),
        async result() {
          try {
            const message = await response.result();
            if (!recorded) {
              recorded = true;
              for (const key of Object.keys(totalUsage)) totalUsage[key] += message.usage?.[key] ?? 0;
              const tokens = message.usage?.totalTokens;
              if (Number.isSafeInteger(tokens) && tokens > 0) turnAccounts[index] = { tokens, estimated: false };
              reportUsage();
            }
            return message;
          } finally { clearTimeout(controller.modelTimer); controller.modelTimer = null; }
        },
      };
    };
    // Guard the SDK's request preparation boundary as well as the call itself.
    const previousPrepareRequest = state.session.agent.prepareRequest;
    state.session.agent.prepareRequest = async (request, signal) => {
      if (controller.cancelled || controller.limitReason || signal?.aborted) {
        throw new Error("Task stopped before model request");
      }
      const prepared = await previousPrepareRequest?.(request, signal);
      if (controller.cancelled || controller.limitReason || signal?.aborted) {
        throw new Error("Task stopped before model request");
      }
      return prepared;
    };
    const unsubscribe = state.session.subscribe((item) => {
      if (item.type === "message_update" && item.assistantMessageEvent.type === "text_delta") {
        if (budgetAnswer !== null) budgetAnswer += item.assistantMessageEvent.delta;
        else event(runID, "text_delta", { text: item.assistantMessageEvent.delta });
      }
      if (item.type === "message_end" && item.message.role === "assistant") {
        if (budgetAnswer !== null) {
          // Some gateways return tool markup as ordinary text when the tool list
          // is removed. Never expose that protocol residue as the final answer.
          if (/<[^>]{0,120}DSML[^>]*>|<\|[^>]{0,120}(?:calls|tool)/i.test(budgetAnswer)) {
            invalidBudgetAnswer = true;
          } else if (budgetAnswer.trim()) {
            event(runID, "text_delta", { text: budgetAnswer });
          }
          budgetAnswer = null;
        }
        lastMessage = item.message;
      }
    });
    try {
      const contextWindow = connection.contextWindow ?? 128000;
      const estimatedContext = Buffer.byteLength(JSON.stringify({ system, messages: state.session.messages, prompt }));
      const reserve = Math.max((connection.maxOutputTokens ?? 1200) + 2048, Math.floor(contextWindow * 0.15));
      if (state.session.messages.length >= 4 && estimatedContext > Math.max(1024, contextWindow - reserve)) {
        await state.session.compact("保留用户的问题、关键事实、引用编号和未解决的问题。");
        if (controller.cancelled || controller.limitReason) throw new Error("Task stopped after compaction");
      }
      await state.session.prompt(prompt);
    } finally {
      state.session.agent.streamFunction = previousStreamFunction;
      state.session.agent.prepareRequest = previousPrepareRequest;
      unsubscribe();
    }
    if (controller.cancelled) terminal = { type: "cancelled" };
    else if (invalidBudgetAnswer) terminal = { type: "error", message: "模型未能在本轮额度内生成结论，请继续分析或更换模型。" };
    else if (controller.limitReason) terminal = { type: "error", message: controller.limitReason };
    else if (!lastMessage || lastMessage.stopReason === "error" || lastMessage.stopReason === "aborted") terminal = { type: "error", message: "模型请求失败，请检查连接与模型配置。" };
    else terminal = { type: "completed", usage: totalUsage, stopReason: lastMessage.stopReason, modelRequests: controller.modelRequests };
  } catch {
    terminal = controller.cancelled ? { type: "cancelled" } : { type: "error", message: controller.limitReason ?? "Agent 运行失败，请检查连接与运行时配置。" };
  } finally {
    pauseClock(controller);
    clearTimeout(controller.modelTimer);
    for (const pending of pendingTools.values()) if (pending.runID === runID) pending.abort();
    if (params.ephemeral === true) {
      sessions.get(sessionID)?.session.dispose();
      sessions.delete(sessionID);
    }
    await hosted.close();
    runs.delete(runID);
    if (terminal) {
      const { type, ...data } = terminal;
      event(runID, type, data);
    }
  }
}

async function dispatch(message) {
  const { id, method, params = {} } = message;
  if (method === "hello") {
    try {
      const runtime = JSON.parse(await readFile(new URL("./package.json", import.meta.url), "utf8"));
      const pi = JSON.parse(await readFile(new URL("./node_modules/@earendil-works/pi-coding-agent/package.json", import.meta.url), "utf8"));
      return reply(id, { protocol: 1, runtime: runtime.version, pi: pi.version, capabilities: ["stream", "cancel", "sessions"] });
    } catch { return failure(id, -32000, "Runtime metadata unavailable"); }
  }
  if (method === "selfTest") {
    try { return reply(id, await runtimeSelfTest(loader)); }
    catch { return failure(id, -32000, "Runtime self-test failed"); }
  }
  if (method === "mcpDiscover") {
    if (typeof id !== "string" || !id || discoveries.has(id) || discoveries.size >= 2 || !params.config) {
      return failure(id, -32602, "Invalid MCP discovery request");
    }
    let client;
    try {
      client = new ManagedMcpConnection(params.config, [], () => false, { discoverOnly: true });
      discoveries.set(id, client);
      const tools = await client.connect();
      if (discoveries.get(id) !== client) return failure(id, -32002, "MCP discovery cancelled");
      if (tools.some(tool => !tool.name || tool.name.length > 256)) throw new Error("Invalid tool names");
      const result = tools.slice(0, 100).map(tool => ({ name: tool.name, description: typeof tool.description === "string" ? tool.description.slice(0, 1000) : "" }));
      if (new Set(result.map(tool => tool.name)).size !== result.length) throw new Error("Invalid tool names");
      reply(id, { tools: result, truncated: tools.length > 100 });
    } catch { failure(id, -32000, "无法连接 MCP 服务或读取工具列表。"); }
    finally { discoveries.delete(id); await client?.close(); }
    return;
  }
  if (method === "mcpDiscoverCancel") {
    const client = discoveries.get(params.requestID);
    discoveries.delete(params.requestID);
    if (client) await client.close();
    return reply(id, { cancelled: !!client });
  }
  if (method === "run") return run(id, params);
  if (method === "cancel") {
    const controller = runs.get(params.runID);
    if (controller) { controller.cancelled = true; controller.session?.abortCompaction(); await controller.session?.abort(); }
    return reply(id, { cancelled: !!controller });
  }
  if (method === "toolResult") {
    const pending = pendingTools.get(params.requestID);
    if (!pending || pending.runID !== params.runID || typeof params.text !== "string" || params.text.length > 100000) {
      return failure(id, -32602, "Invalid or expired tool result");
    }
    pendingTools.delete(params.requestID);
    pending.finish(params.text);
    return reply(id, { accepted: true });
  }
  if (method === "closeSession") {
    if ([...runs.values()].some((r) => r.sessionID === params.sessionID)) return failure(id, -32001, "Session is busy");
    sessions.get(params.sessionID)?.session.dispose();
    sessions.delete(params.sessionID);
    return reply(id, { closed: true });
  }
  failure(id, -32601, "Unknown method");
}

process.stdin.on("data", (chunk) => {
  input = Buffer.concat([input, chunk]);
  while (input.length >= 4) {
    const size = input.readUInt32BE(0);
    if (size > MAX_FRAME) { process.stderr.write("Invalid frame length\n"); process.exit(1); }
    if (input.length < size + 4) return;
    const frame = input.subarray(4, size + 4);
    input = input.subarray(size + 4);
    try { Promise.resolve(dispatch(JSON.parse(frame.toString("utf8")))).catch(() => {}); }
    catch { failure(null, -32700, "Invalid JSON"); }
  }
});
process.stdin.on("end", () => { for (const state of sessions.values()) state.session.dispose(); for (const client of discoveries.values()) void client.close(); process.exit(0); });
