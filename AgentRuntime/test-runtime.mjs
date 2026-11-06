import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { createServer } from "node:http";
import { once } from "node:events";
import { setTimeout as delay } from "node:timers/promises";
import { readFile } from "node:fs/promises";

const requests = [];
const server = createServer(async (request, response) => {
  let body = "";
  for await (const chunk of request) body += chunk;
  requests.push({ url: request.url, authorization: request.headers.authorization, apiKey: request.headers["x-api-key"], custom: request.headers["x-fixture"], body: JSON.parse(body) });
  if (body.includes("预算重试回归")) {
    const status = body.includes("限流") ? 429 : 500;
    response.writeHead(status, { "content-type": "application/json", "retry-after": "0" }).end(JSON.stringify({ error: { message: "fixture failure", type: "api_error" } }));
    return;
  }
  if (request.url === "/redirect/v1/chat/completions") {
    response.writeHead(302, { location: `http://127.0.0.1:${server.address().port}/v1/chat/completions` }).end();
    return;
  }
  if (body.includes("取消测试")) {
    response.writeHead(200, { "content-type": "text/event-stream" });
    response.flushHeaders();
    return;
  }
  if (body.includes("# Conversation") && body.includes("压缩中取消")) {
    response.writeHead(200, { "content-type": "text/event-stream" });
    response.flushHeaders();
    return;
  }
  response.writeHead(200, { "content-type": "text/event-stream" });
  const chunk = (data) => response.write(`data: ${JSON.stringify(data)}\n\n`);
  if (body.includes("预算内完成研究")) {
    const payload = JSON.parse(body);
    const isResponses = request.url?.includes("/responses");
    const isAnthropic = request.url?.includes("/messages");
    if (isResponses || isAnthropic) {
      const useTool = !!payload.tools?.length && !body.includes("预算追问");
      const answer = body.includes("预算追问") ? "追问完成" : "依据已有材料完成研究";
      if (isResponses) {
        const item = useTool
          ? { id: `fc-${requests.length}`, type: "function_call", call_id: `call-${requests.length}`, name: "open_ai_page", arguments: '{"url":"https://example.com/"}', status: "completed" }
          : { id: "msg-budget", type: "message", role: "assistant", status: "completed", content: [{ type: "output_text", text: answer, annotations: [] }] };
        chunk({ type: "response.created", response: { id: "resp-budget" } });
        chunk({ type: "response.output_item.added", output_index: 0, item: useTool ? { ...item, arguments: "", status: "in_progress" } : { ...item, content: [], status: "in_progress" } });
        if (useTool) chunk({ type: "response.function_call_arguments.delta", output_index: 0, delta: item.arguments });
        else chunk({ type: "response.output_text.delta", output_index: 0, content_index: 0, delta: answer });
        chunk({ type: "response.output_item.done", output_index: 0, item });
        chunk({ type: "response.completed", response: { id: "resp-budget", status: "completed", output: [item], usage: { input_tokens: 5, output_tokens: 3, total_tokens: 8, input_tokens_details: { cached_tokens: 0 }, output_tokens_details: { reasoning_tokens: 0 } } } });
      } else {
        const send = (value) => response.write(`event: ${value.type}\ndata: ${JSON.stringify(value)}\n\n`);
        send({ type: "message_start", message: { id: "msg-budget", type: "message", role: "assistant", model: "mock-model", content: [], usage: { input_tokens: 5, output_tokens: 0 } } });
        send({ type: "content_block_start", index: 0, content_block: useTool ? { type: "tool_use", id: `call-${requests.length}`, name: "open_ai_page", input: {} } : { type: "text", text: "" } });
        send({ type: "content_block_delta", index: 0, delta: useTool ? { type: "input_json_delta", partial_json: '{"url":"https://example.com/"}' } : { type: "text_delta", text: answer } });
        send({ type: "content_block_stop", index: 0 });
        send({ type: "message_delta", delta: { stop_reason: useTool ? "tool_use" : "end_turn", stop_sequence: null }, usage: { output_tokens: 3 } });
        send({ type: "message_stop" });
      }
      response.end();
      return;
    }
    if (body.includes("预算追问")) {
      assert.ok(payload.tools?.length, "后续追问应恢复工具");
      chunk({ id: "budget-followup", object: "chat.completion.chunk", created: 1, model: "mock-model", choices: [{ index: 0, delta: { role: "assistant", content: "追问完成" }, finish_reason: "stop" }] });
    } else if (payload.tools?.length) {
      chunk({ id: "budget", object: "chat.completion.chunk", created: 1, model: "mock-model", choices: [{ index: 0, delta: { role: "assistant", tool_calls: [{ index: 0, id: `call-${requests.length}`, type: "function", function: { name: "open_ai_page", arguments: '{"url":"https://example.com/"}' } }] }, finish_reason: null }] });
      chunk({ id: "budget", object: "chat.completion.chunk", created: 1, model: "mock-model", choices: [{ index: 0, delta: {}, finish_reason: "tool_calls" }] });
    } else {
      chunk({ id: "budget", object: "chat.completion.chunk", created: 1, model: "mock-model", choices: [{ index: 0, delta: { role: "assistant", content: "依据已有材料完成研究" }, finish_reason: "stop" }] });
    }
    response.end("data: [DONE]\n\n");
    return;
  }
  if (["/v1/responses", "/gateway/v1/responses"].includes(request.url)) {
    assert.equal(JSON.parse(body).store, false);
    const item = { id: "msg1", type: "message", role: "assistant", status: "completed", content: [{ type: "output_text", text: "Responses 成功", annotations: [] }] };
    chunk({ type: "response.created", response: { id: "resp1" } });
    chunk({ type: "response.output_item.added", output_index: 0, item: { ...item, content: [], status: "in_progress" } });
    chunk({ type: "response.output_text.delta", output_index: 0, content_index: 0, delta: "Responses 成功" });
    chunk({ type: "response.output_item.done", output_index: 0, item });
    chunk({ type: "response.completed", response: { id: "resp1", status: "completed", output: [item], usage: { input_tokens: 5, output_tokens: 3, total_tokens: 8, input_tokens_details: { cached_tokens: 0 }, output_tokens_details: { reasoning_tokens: 0 } } } });
    response.end();
    return;
  }
  if (request.url?.startsWith("/v1/messages") || request.url?.startsWith("/gateway/v1/messages")) {
    assert.equal(request.headers["x-api-key"], "secret-for-test");
    const send = (value) => response.write(`event: ${value.type}\ndata: ${JSON.stringify(value)}\n\n`);
    send({ type: "message_start", message: { id: "msg1", type: "message", role: "assistant", model: "mock-model", content: [], usage: { input_tokens: 5, output_tokens: 0 } } });
    send({ type: "content_block_start", index: 0, content_block: { type: "text", text: "" } });
    send({ type: "content_block_delta", index: 0, delta: { type: "text_delta", text: "Anthropic 成功" } });
    send({ type: "content_block_stop", index: 0 });
    send({ type: "message_delta", delta: { stop_reason: "end_turn", stop_sequence: null }, usage: { output_tokens: 3 } });
    send({ type: "message_stop" });
    response.end();
    return;
  }
  if (!body.includes("<conversation>") && !body.includes("# Conversation") && (body.includes("MCP批准") || body.includes("MCP拒绝") || body.includes("MCP取消") || body.includes("MCP目录"))) {
    const payload = JSON.parse(body);
    if (!payload.messages.some(message => message.role === "tool")) {
      const listing = body.includes("MCP目录");
      const name = listing ? "mcp_list_tools" : "mcp_call_tool";
      const args = listing ? { serverID: "fixture" } : { serverID: "fixture", toolName: "echo", argumentsJSON: JSON.stringify({ value: "research" }) };
      assert.ok(payload.tools.some(tool => tool.function.name === name));
      chunk({ id: "mcpmock", object: "chat.completion.chunk", created: 1, model: "mock-model", choices: [{ index: 0, delta: { role: "assistant", tool_calls: [{ index: 0, id: "mcp-call", type: "function", function: { name, arguments: JSON.stringify(args) } }] }, finish_reason: null }] });
      chunk({ id: "mcpmock", object: "chat.completion.chunk", created: 1, model: "mock-model", choices: [{ index: 0, delta: {}, finish_reason: "tool_calls" }] });
    } else {
      const toolOutput = JSON.stringify(payload.messages.filter(message => message.role === "tool"));
      if (body.includes("MCP批准")) assert.ok(toolOutput.includes("research"));
      if (body.includes("MCP拒绝")) assert.ok(toolOutput.includes("未获授权"));
      if (body.includes("MCP目录")) { assert.ok(toolOutput.includes("echo")); assert.ok(!toolOutput.includes("disabled")); }
      chunk({ id: "mcpmock", object: "chat.completion.chunk", created: 1, model: "mock-model", choices: [{ index: 0, delta: { role: "assistant", content: "研究完成" }, finish_reason: "stop" }] });
    }
    response.end("data: [DONE]\n\n");
    return;
  }
  if ((!body.includes("<conversation>") && !body.includes("# Conversation") && body.includes("工具压缩")) ||
      (body.includes("large-tool") && JSON.parse(body).messages?.at(-1)?.role === "tool")) {
    const payload = JSON.parse(body);
    if (!payload.messages.some(message => message.role === "tool")) {
      chunk({ id: "compact-tool", object: "chat.completion.chunk", created: 1, model: "mock-model", choices: [{ index: 0, delta: { role: "assistant", tool_calls: [{ index: 0, id: "large-tool", type: "function", function: { name: "open_ai_page", arguments: '{"url":"https://example.com/"}' } }] }, finish_reason: null }] });
      chunk({ id: "compact-tool", object: "chat.completion.chunk", created: 1, model: "mock-model", choices: [{ index: 0, delta: {}, finish_reason: "tool_calls" }], usage: { prompt_tokens: 12, completion_tokens: 3, total_tokens: 15 } });
    } else {
      chunk({ id: "compact-tool", object: "chat.completion.chunk", created: 1, model: "mock-model", choices: [{ index: 0, delta: { role: "assistant", content: "研究完成" }, finish_reason: "stop" }], usage: { prompt_tokens: 3500, completion_tokens: 20, total_tokens: 3520 } });
    }
    response.end("data: [DONE]\n\n");
    return;
  }
  if (!body.includes("<conversation>") && !body.includes("# Conversation") && (body.includes("申请按钮") || body.includes("申请提交") || body.includes("请求工具") || body.includes("申请授权") || body.includes("等待验证") || body.includes("观察链接") || body.includes("打开链接") || body.includes("读取公开网页") || body.includes("页面内查找") || body.includes("展开区域") || body.includes("查看热榜"))) {
    const payload = JSON.parse(body);
    if (!payload.messages.some((m) => m.role === "tool")) {
      const asking = body.includes("申请授权");
      const login = body.includes("等待验证");
      const observe = body.includes("观察链接");
      const follow = body.includes("打开链接");
      const publicArticle = body.includes("读取公开网页");
      const find = body.includes("页面内查找");
      const expand = body.includes("展开区域");
      const hot = body.includes("查看热榜");
      const submit = body.includes("申请提交");
      const button = body.includes("申请按钮");
      const name = button ? "click_ai_button" : (submit ? "submit_ai_form" : (hot ? "current_hot_topics" : (asking ? "request_user_page" : (login ? "wait_for_login" : (observe ? "observe_ai_page" : (follow ? "open_ai_page_link" : (publicArticle ? "read_public_article" : (find ? "find_ai_page" : (expand ? "expand_ai_section" : "open_ai_page")))))))));
      const args = hot ? '{"tabID":"test-tab"}' : (asking ? '{"reason":"查看当前文章"}' : (find ? '{"tabID":"test-tab","query":"关键词"}' : ((login || observe) ? '{"tabID":"test-tab"}' : ((follow || expand || submit || button) ? '{"reference":"test-ref"}' : '{"url":"https://example.com/"}'))));
      assert.ok(payload.tools.some((tool) => tool.function.name === name));
      chunk({ id: "toolmock", object: "chat.completion.chunk", created: 1, model: "mock-model", choices: [{ index: 0, delta: { role: "assistant", tool_calls: [{ index: 0, id: "call1", type: "function", function: { name, arguments: args } }] }, finish_reason: null }] });
      chunk({ id: "toolmock", object: "chat.completion.chunk", created: 1, model: "mock-model", choices: [{ index: 0, delta: {}, finish_reason: "tool_calls" }] });
    } else {
      assert.ok(JSON.stringify(payload.messages).includes("页面标识 fixture"));
      chunk({ id: "toolmock", object: "chat.completion.chunk", created: 1, model: "mock-model", choices: [{ index: 0, delta: { role: "assistant", content: "已阅读" }, finish_reason: "stop" }], usage: { prompt_tokens: 12, completion_tokens: 3, total_tokens: 15 } });
    }
    response.end("data: [DONE]\n\n");
    return;
  }
  chunk({ id: "mock", object: "chat.completion.chunk", created: 1, model: "mock-model", choices: [{ index: 0, delta: { role: "assistant", content: "测试" }, finish_reason: null }] });
  chunk({ id: "mock", object: "chat.completion.chunk", created: 1, model: "mock-model", choices: [{ index: 0, delta: { content: "完成" }, finish_reason: null }] });
  chunk({ id: "mock", object: "chat.completion.chunk", created: 1, model: "mock-model", choices: [{ index: 0, delta: {}, finish_reason: "stop" }], usage: { prompt_tokens: 12, completion_tokens: 3, total_tokens: 15 } });
  response.end("data: [DONE]\n\n");
});
server.listen(0, "127.0.0.1");
await once(server, "listening");
const child = spawn(process.execPath, [new URL("./runtime.mjs", import.meta.url).pathname], { stdio: ["pipe", "pipe", "pipe"] });
let input = Buffer.alloc(0);
let stderr = "";
const messages = [];
child.stderr.on("data", (chunk) => { stderr += chunk; });
child.stdout.on("data", (chunk) => {
  input = Buffer.concat([input, chunk]);
  while (input.length >= 4 && input.length >= 4 + input.readUInt32BE(0)) {
    const length = input.readUInt32BE(0);
    messages.push(JSON.parse(input.subarray(4, length + 4)));
    input = input.subarray(length + 4);
  }
});
function send(message) {
  const body = Buffer.from(JSON.stringify(message));
  const header = Buffer.alloc(4); header.writeUInt32BE(body.length);
  // Deliberately split the frame to exercise partial reads.
  child.stdin.write(header.subarray(0, 2)); child.stdin.write(Buffer.concat([header.subarray(2), body]));
}
async function waitFor(predicate) {
  for (let i = 0; i < 200; i++) {
    const message = messages.find(predicate);
    if (message) return message;
    await delay(25);
  }
  throw new Error(`timeout: ${JSON.stringify(messages)}; stderr=${stderr}`);
}

try {
  send({ jsonrpc: "2.0", id: 1, method: "hello" });
  const hello = (await waitFor((m) => m.id === 1)).result;
  const packageMetadata = JSON.parse(await readFile(new URL("./package.json", import.meta.url), "utf8"));
  const piMetadata = JSON.parse(await readFile(new URL("./node_modules/@earendil-works/pi-coding-agent/package.json", import.meta.url), "utf8"));
  assert.equal(hello.protocol, 1);
  assert.equal(hello.runtime, packageMetadata.version);
  assert.equal(hello.pi, piMetadata.version);
  send({ jsonrpc: "2.0", id: "selftest", method: "selfTest" });
  assert.deepEqual((await waitFor(message => message.id === "selftest")).result, { protocol: 1, streaming: true, tools: true });
  const connection = { id: "a", kind: "openai-chat", baseURL: `http://127.0.0.1:${server.address().port}/v1`, model: "mock-model", maxOutputTokens: 1200 };
  send({ jsonrpc: "2.0", id: 2, method: "run", params: { runID: "first", sessionID: "session", connection, apiKey: "secret-for-test", system: "测试系统", prompt: "第一问" } });
  assert.equal((await waitFor((m) => m.id === 2)).result.accepted, true);
  const completed = await waitFor((m) => m.params?.runID === "first" && ["completed", "error"].includes(m.params.type));
  assert.equal(completed.params.type, "completed");
  const firstUsage = messages.filter(m => m.params?.runID === "first" && m.params.type === "usage_progress").at(-1).params;
  assert.equal(firstUsage.accountedTokens, 15);
  assert.equal(firstUsage.estimatedUsage, false);
  assert.equal(firstUsage.modelRequests, 1);
  assert.equal(messages.filter((m) => m.params?.runID === "first" && m.params.type === "text_delta").map((m) => m.params.text).join(""), "测试完成");
  assert.equal(requests[0].url, "/v1/chat/completions");
  assert.equal(requests[0].authorization, "Bearer secret-for-test");
  send({ jsonrpc: "2.0", id: 3, method: "run", params: { runID: "second", sessionID: "session", connection, apiKey: "secret-for-test", system: "测试系统", prompt: "第二问" } });
  const second = await waitFor((m) => m.params?.runID === "second" && ["completed", "error"].includes(m.params.type));
  assert.equal(second.params.type, "completed");
  assert.ok(JSON.stringify(requests[1].body).includes("第一问"));
  assert.ok(JSON.stringify(requests[1].body).includes("第二问"));
  assert.ok(!JSON.stringify(messages).includes("secret-for-test"));
  send({ jsonrpc: "2.0", id: 5, method: "run", params: { runID: "cancelled", sessionID: "other", connection, apiKey: "secret-for-test", prompt: "取消测试" } });
  for (let i = 0; i < 200 && requests.length < 3; i++) await delay(25);
  assert.equal(requests.length, 3);
  const interruptedUsage = messages.find(m => m.params?.runID === "cancelled" && m.params.type === "usage_progress").params;
  assert.equal(interruptedUsage.modelRequests, 1);
  assert.equal(interruptedUsage.estimatedUsage, true);
  assert.ok(interruptedUsage.accountedTokens > 0);
  send({ jsonrpc: "2.0", id: 6, method: "cancel", params: { runID: "cancelled" } });
  assert.equal((await waitFor((m) => m.id === 6)).result.cancelled, true);
  assert.equal((await waitFor((m) => m.params?.runID === "cancelled" && m.params.type === "cancelled")).params.type, "cancelled");
  send({ jsonrpc: "2.0", id: 7, method: "run", params: { runID: "research", sessionID: "research-session", connection, apiKey: "secret-for-test", prompt: "请求工具", tools: ["open_ai_page"] } });
  const tool = (await waitFor((m) => m.params?.runID === "research" && m.params.type === "tool_request")).params.toolRequest;
  assert.equal(tool.name, "open_ai_page");
  assert.equal(tool.arguments.url, "https://example.com/");
  send({ jsonrpc: "2.0", id: 8, method: "toolResult", params: { runID: "research", requestID: tool.requestID, text: "页面标识 fixture" } });
  assert.equal((await waitFor((m) => m.id === 8)).result.accepted, true);
  assert.equal((await waitFor((m) => m.params?.runID === "research" && ["completed", "error"].includes(m.params.type))).params.type, "completed");
  const mixedUsage = messages.filter(m => m.params?.runID === "research" && m.params.type === "usage_progress").at(-1).params;
  assert.equal(mixedUsage.modelRequests, 2);
  assert.equal(mixedUsage.estimatedUsage, true);
  assert.ok(mixedUsage.accountedTokens > 15);
  const budgetStart = requests.length;
  const handledBudget = new Set();
  send({ jsonrpc: "2.0", id: "budget-run", method: "run", params: { runID: "budget-run", sessionID: "budget-session", connection, apiKey: "secret-for-test", prompt: "预算内完成研究", tools: ["open_ai_page"], limits: { maxRequests: 3 } } });
  for (let index = 0; index < 2; index++) {
    const call = (await waitFor(m => m.params?.runID === "budget-run" && m.params.type === "tool_request" && !handledBudget.has(m.params.toolRequest.requestID))).params.toolRequest;
    handledBudget.add(call.requestID);
    send({ jsonrpc: "2.0", id: `budget-result-${index}`, method: "toolResult", params: { runID: "budget-run", requestID: call.requestID, text: "证据材料" } });
  }
  assert.equal((await waitFor(m => m.params?.runID === "budget-run" && ["completed", "error"].includes(m.params.type))).params.type, "completed");
  assert.equal(requests.length - budgetStart, 3);
  assert.ok(!requests.at(-1).body.tools?.length);
  assert.ok(JSON.stringify(requests.at(-1).body).includes("依据已有"));
  assert.ok(messages.some(m => m.params?.runID === "budget-run" && m.params.type === "text_delta" && m.params.text.includes("依据已有材料完成研究")));
  send({ jsonrpc: "2.0", id: "budget-followup", method: "run", params: { runID: "budget-followup", sessionID: "budget-session", connection, apiKey: "secret-for-test", prompt: "预算追问", tools: ["open_ai_page"] } });
  assert.equal((await waitFor(m => m.params?.runID === "budget-followup" && ["completed", "error"].includes(m.params.type))).params.type, "completed");
  for (const kind of ["openai-responses", "anthropic-messages"]) {
    const runID = `budget-${kind}`;
    const start = requests.length;
    const handled = new Set();
    const provider = { ...connection, id: runID, kind };
    send({ jsonrpc: "2.0", id: runID, method: "run", params: { runID, sessionID: runID, connection: provider, apiKey: "secret-for-test", prompt: "预算内完成研究", tools: ["open_ai_page"], limits: { maxRequests: 3 } } });
    for (let index = 0; index < 2; index++) {
      const call = (await waitFor(m => m.params?.runID === runID && m.params.type === "tool_request" && !handled.has(m.params.toolRequest.requestID))).params.toolRequest;
      handled.add(call.requestID);
      send({ jsonrpc: "2.0", id: `${runID}-tool-${index}`, method: "toolResult", params: { runID, requestID: call.requestID, text: "已有证据" } });
    }
    const finished = await waitFor(m => m.params?.runID === runID && ["completed", "error"].includes(m.params.type));
    assert.equal(finished.params.type, "completed", JSON.stringify(finished));
    assert.equal(requests.length - start, 3, kind);
    assert.ok(!requests.at(-1).body.tools?.length, kind);
    assert.ok(messages.some(m => m.params?.runID === runID && m.params.type === "text_delta" && m.params.text.includes("依据已有材料完成研究")), kind);
    const follow = `${runID}-follow`;
    send({ jsonrpc: "2.0", id: follow, method: "run", params: { runID: follow, sessionID: runID, connection: provider, apiKey: "secret-for-test", prompt: "预算追问", tools: ["open_ai_page"] } });
    assert.equal((await waitFor(m => m.params?.runID === follow && ["completed", "error"].includes(m.params.type))).params.type, "completed", kind);
    assert.ok(requests.at(-1).body.tools?.length, kind);
  }
  for (const [id, name, prompt, argument, expected] of [[27, "observe_ai_page", "观察链接", "tabID", "test-tab"], [29, "open_ai_page_link", "打开链接", "reference", "test-ref"], [36, "read_public_article", "读取公开网页", "url", "https://example.com/"], [38, "find_ai_page", "页面内查找", "query", "关键词"], [40, "expand_ai_section", "展开区域", "reference", "test-ref"], [101, "current_hot_topics", "查看热榜", "tabID", "test-tab"]]) {
    send({ jsonrpc: "2.0", id, method: "run", params: { runID: name, sessionID: name, connection, apiKey: "secret-for-test", prompt, tools: [name] } });
    const call = (await waitFor((m) => m.params?.runID === name && m.params.type === "tool_request")).params.toolRequest;
    assert.equal(call.name, name);
    assert.equal(call.arguments[argument], expected);
    send({ jsonrpc: "2.0", id: id + 1, method: "toolResult", params: { runID: name, requestID: call.requestID, text: "页面标识 fixture" } });
    assert.equal((await waitFor((m) => m.params?.runID === name && ["completed", "error"].includes(m.params.type))).params.type, "completed");
  }
  send({ jsonrpc: "2.0", id: 9, method: "run", params: { runID: "research-cancel", sessionID: "cancel-tool-session", connection, apiKey: "secret-for-test", prompt: "请求工具", tools: ["open_ai_page"] } });
  const waiting = (await waitFor((m) => m.params?.runID === "research-cancel" && m.params.type === "tool_request")).params.toolRequest;
  send({ jsonrpc: "2.0", id: 10, method: "cancel", params: { runID: "research-cancel" } });
  assert.equal((await waitFor((m) => m.params?.runID === "research-cancel" && m.params.type === "cancelled")).params.type, "cancelled");
  send({ jsonrpc: "2.0", id: 11, method: "toolResult", params: { runID: "research-cancel", requestID: waiting.requestID, text: "stale result" } });
  assert.equal((await waitFor((m) => m.id === 11)).error.code, -32602);
  const mcpServers = [{ id: "fixture", name: "测试服务", config: { type: "stdio", command: process.execPath,
    args: [new URL("./test-mcp-server.mjs", import.meta.url).pathname], env: {} }, enabledTools: ["echo"] }];
  send({ jsonrpc: "2.0", id: "discover", method: "mcpDiscover", params: { config: mcpServers[0].config } });
  const discovery = (await waitFor(message => message.id === "discover")).result;
  assert.deepEqual(discovery.tools.map(tool => tool.name), ["echo", "disabled"]);
  assert.equal(discovery.truncated, false);
  send({ jsonrpc: "2.0", id: "slow-discovery", method: "mcpDiscover", params: { config: { ...mcpServers[0].config, env: { DELAY_INITIALIZE: "1" } } } });
  await delay(100);
  send({ jsonrpc: "2.0", id: "stop-discovery", method: "mcpDiscoverCancel", params: { requestID: "slow-discovery" } });
  assert.equal((await waitFor(message => message.id === "stop-discovery")).result.cancelled, true);
  assert.ok((await waitFor(message => message.id === "slow-discovery")).error);
  for (const [id, label, decision] of [[41, "批准", "allow"], [43, "拒绝", "deny"], [45, "取消", null]]) {
    const runID = `mcp-${label}`;
    send({ jsonrpc: "2.0", id, method: "run", params: { runID, sessionID: runID, connection,
      apiKey: "secret-for-test", prompt: `MCP${label}`, tools: ["mcp_call_tool"], mcpServers, ephemeral: true } });
    const approval = (await waitFor(message => message.params?.runID === runID && message.params.type === "tool_request")).params.toolRequest;
    assert.equal(approval.name, "mcp_authorize");
    assert.equal(approval.arguments.serverID, "fixture");
    assert.deepEqual(JSON.parse(approval.arguments.argumentsJSON), { value: "research" });
    if (decision) {
      send({ jsonrpc: "2.0", id: id + 1, method: "toolResult", params: { runID, requestID: approval.requestID, text: decision } });
      assert.equal((await waitFor(message => message.params?.runID === runID && ["completed", "error"].includes(message.params.type))).params.type, "completed");
    } else {
      send({ jsonrpc: "2.0", id: id + 1, method: "cancel", params: { runID } });
      assert.equal((await waitFor(message => message.params?.runID === runID && message.params.type === "cancelled")).params.type, "cancelled");
    }
  }
  send({ jsonrpc: "2.0", id: 47, method: "run", params: { runID: "mcp-list", sessionID: "mcp-list", connection,
    apiKey: "secret-for-test", prompt: "MCP目录", tools: ["mcp_list_tools"], mcpServers, ephemeral: true } });
  assert.equal((await waitFor(message => message.params?.runID === "mcp-list" && ["completed", "error"].includes(message.params.type))).params.type, "completed");
  send({ jsonrpc: "2.0", id: 48, method: "run", params: { runID: "mcp-invalid", sessionID: "mcp-invalid", connection,
    apiKey: "secret-for-test", prompt: "MCP目录", tools: ["mcp_list_tools"], mcpServers } });
  assert.equal((await waitFor(message => message.id === 48)).error.code, -32602);
  for (const [id, kind, expected] of [[12, "openai-responses", "Responses 成功"], [13, "anthropic-messages", "Anthropic 成功"]]) {
    send({ jsonrpc: "2.0", id, method: "run", params: { runID: kind, sessionID: kind, connection: { ...connection, id: kind, kind }, apiKey: "secret-for-test", prompt: "测试协议" } });
    const finish = await waitFor((m) => m.params?.runID === kind && ["completed", "error"].includes(m.params.type));
    assert.equal(finish.params.type, "completed", `${kind}: ${JSON.stringify(requests.map((r) => r.url))}`);
    assert.equal(messages.filter((m) => m.params?.runID === kind && m.params.type === "text_delta").map((m) => m.params.text).join(""), expected);
  }
  for (const [id, kind, path] of [[14, "openai-responses", "/gateway/v1/responses"], [15, "anthropic-messages", "/gateway/v1/messages"]]) {
    const runID = `custom-${kind}`;
    send({ jsonrpc: "2.0", id, method: "run", params: { runID, sessionID: runID,
      connection: { ...connection, id: runID, kind, baseURL: `http://127.0.0.1:${server.address().port}/gateway/v1` }, apiKey: "secret-for-test", prompt: "测试网关" } });
    assert.equal((await waitFor((m) => m.params?.runID === runID && ["completed", "error"].includes(m.params.type))).params.type, "completed");
    assert.ok(requests.some((request) => request.url.startsWith(path)), path);
  }
  for (const [id, kind] of [[22, "openai-chat"], [23, "openai-responses"], [24, "anthropic-messages"]]) {
    const runID = `history-${kind}`;
    const requestIndex = requests.length;
    send({ jsonrpc: "2.0", id, method: "run", params: { runID, sessionID: runID,
      connection: { ...connection, id: runID, kind }, apiKey: "secret-for-test", system: "测试系统",
      history: [{ role: "user", text: "此前的问题" }, { role: "assistant", text: "此前的回答" }], prompt: "继续追问", ephemeral: true } });
    const finish = await waitFor((m) => m.params?.runID === runID && ["completed", "error"].includes(m.params.type));
    assert.equal(finish.params.type, "completed", kind);
    const body = requests[requestIndex].body;
    const conversation = kind === "openai-responses" ? body.input : body.messages;
    const selected = conversation.filter((message) => ["user", "assistant"].includes(message.role));
    assert.deepEqual(selected.map((message) => message.role), ["user", "assistant", "user"], kind);
    assert.ok(JSON.stringify(selected[0]).includes("此前的问题"), kind);
    assert.ok(JSON.stringify(selected[1]).includes("此前的回答"), kind);
    assert.ok(JSON.stringify(selected[2]).includes("继续追问"), kind);
  }
  const longHistory = Array.from({ length: 10 }, (_, index) => ({
    role: index % 2 === 0 ? "user" : "assistant", text: `${index} ${"长对话材料".repeat(250)}`,
  }));
  const beforeCompaction = requests.length;
  send({ jsonrpc: "2.0", id: "compact", method: "run", params: { runID: "compact", sessionID: "compact", connection: { ...connection, contextWindow: 4096 },
    apiKey: "secret-for-test", system: "测试系统", history: longHistory, prompt: "继续追问", ephemeral: true } });
  const compacted = await waitFor(m => m.params?.runID === "compact" && ["completed", "error"].includes(m.params.type));
  assert.equal(compacted.params.type, "completed", JSON.stringify(compacted));
  assert.equal(requests.length, beforeCompaction + 2);
  assert.ok(JSON.stringify(requests[beforeCompaction + 1].body).includes("测试完成"));
  const compactUsage = messages.filter(m => m.params?.runID === "compact" && m.params.type === "usage_progress").at(-1).params;
  assert.equal(compactUsage.modelRequests, 2);
  assert.equal(compactUsage.accountedTokens, 30);
  assert.equal(compactUsage.estimatedUsage, false);
  const beforeToolCompaction = requests.length;
  send({ jsonrpc: "2.0", id: "tool-compact", method: "run", params: { runID: "tool-compact", sessionID: "tool-compact", connection: { ...connection, contextWindow: 4096 },
    apiKey: "secret-for-test", prompt: "工具压缩", tools: ["open_ai_page"] } });
  const largeTool = (await waitFor(m => m.params?.runID === "tool-compact" && m.params.type === "tool_request")).params.toolRequest;
  send({ jsonrpc: "2.0", id: "tool-compact-result", method: "toolResult", params: { runID: "tool-compact", requestID: largeTool.requestID, text: "长篇资料 ".repeat(8000) } });
  const toolCompacted = await waitFor(m => m.params?.runID === "tool-compact" && ["completed", "error"].includes(m.params.type));
  assert.equal(toolCompacted.params.type, "completed", JSON.stringify(toolCompacted));
  const toolRequests = requests.slice(beforeToolCompaction);
  assert.ok(toolRequests.some(request => /<conversation>|# Conversation/.test(JSON.stringify(request.body))), "工具循环应触发压缩");
  assert.ok(toolRequests.some(request => request.body.messages?.some(message => message.role === "tool" && message.content?.includes("长篇资料"))), "工具材料应送达模型");
  assert.ok(toolRequests.length >= 3);
  assert.equal(messages.filter(m => m.params?.runID === "tool-compact" && m.params.type === "usage_progress").at(-1).params.modelRequests, toolRequests.length);
  const beforeToolFollowup = requests.length;
  send({ jsonrpc: "2.0", id: "tool-compact-followup", method: "run", params: { runID: "tool-compact-followup", sessionID: "tool-compact", connection: { ...connection, contextWindow: 4096 },
    apiKey: "secret-for-test", prompt: "继续追问压缩后的材料", tools: ["open_ai_page"] } });
  assert.equal((await waitFor(m => m.params?.runID === "tool-compact-followup" && ["completed", "error"].includes(m.params.type))).params.type, "completed");
  assert.ok(requests.slice(beforeToolFollowup).some(request => JSON.stringify(request.body).includes("测试完成")), "后续对话应包含压缩摘要");
  const beforeAutoCancel = requests.length;
  send({ jsonrpc: "2.0", id: "auto-compact-cancel", method: "run", params: { runID: "auto-compact-cancel", sessionID: "auto-compact-cancel", connection: { ...connection, contextWindow: 4096 },
    apiKey: "secret-for-test", prompt: "工具压缩，压缩中取消", tools: ["open_ai_page"], ephemeral: true } });
  const autoTool = (await waitFor(m => m.params?.runID === "auto-compact-cancel" && m.params.type === "tool_request")).params.toolRequest;
  send({ jsonrpc: "2.0", id: "auto-compact-tool-result", method: "toolResult", params: { runID: "auto-compact-cancel", requestID: autoTool.requestID, text: "长篇资料 ".repeat(8000) } });
  for (let i = 0; i < 200 && !requests.slice(beforeAutoCancel).some(request => JSON.stringify(request.body).includes("# Conversation")); i++) await delay(25);
  assert.ok(requests.slice(beforeAutoCancel).some(request => JSON.stringify(request.body).includes("# Conversation")));
  const requestsAtCancel = requests.length;
  send({ jsonrpc: "2.0", id: "auto-compact-stop", method: "cancel", params: { runID: "auto-compact-cancel" } });
  assert.equal((await waitFor(m => m.params?.runID === "auto-compact-cancel" && m.params.type === "cancelled")).params.type, "cancelled");
  await delay(100);
  assert.equal(requests.length, requestsAtCancel, "取消压缩后不应发起新请求");
  const beforeCompactLimit = requests.length;
  send({ jsonrpc: "2.0", id: "compact-limit", method: "run", params: { runID: "compact-limit", sessionID: "compact-limit", connection: { ...connection, contextWindow: 4096 },
    apiKey: "secret-for-test", history: longHistory, prompt: "继续追问", ephemeral: true, limits: { maxRequests: 1 } } });
  assert.match((await waitFor(m => m.params?.runID === "compact-limit" && m.params.type === "error")).params.message, /次数上限/);
  assert.equal(requests.length, beforeCompactLimit + 1);
  const beforeCompactCancel = requests.length;
  const slowHistory = longHistory.map((entry, index) => index === 0 ? { ...entry, text: entry.text + "取消测试" } : entry);
  send({ jsonrpc: "2.0", id: "compact-cancel", method: "run", params: { runID: "compact-cancel", sessionID: "compact-cancel", connection: { ...connection, contextWindow: 4096 },
    apiKey: "secret-for-test", history: slowHistory, prompt: "继续追问", ephemeral: true } });
  for (let i = 0; i < 200 && requests.length === beforeCompactCancel; i++) await delay(25);
  assert.equal(requests.length, beforeCompactCancel + 1);
  send({ jsonrpc: "2.0", id: "compact-cancel-request", method: "cancel", params: { runID: "compact-cancel" } });
  assert.equal((await waitFor(m => m.params?.runID === "compact-cancel" && m.params.type === "cancelled")).params.type, "cancelled");
  const beforeLimit = requests.length;
  send({ jsonrpc: "2.0", id: 16, method: "run", params: { runID: "limited", sessionID: "limited", connection,
    apiKey: "secret-for-test", prompt: "请求工具", tools: ["open_ai_page"], limits: { maxRequests: 1 } } });
  const limited = (await waitFor((m) => m.params?.runID === "limited" && m.params.type === "tool_request")).params.toolRequest;
  send({ jsonrpc: "2.0", id: 17, method: "toolResult", params: { runID: "limited", requestID: limited.requestID, text: "页面标识 fixture" } });
  assert.match((await waitFor((m) => m.params?.runID === "limited" && m.params.type === "error")).params.message, /次数上限/);
  assert.equal(requests.length, beforeLimit + 1);
  for (let attempt = 0; attempt < 4; attempt++) {
    const runID = `limit-repeat-${attempt}`;
    const before = requests.length;
    send({ jsonrpc: "2.0", id: `limit-start-${attempt}`, method: "run", params: { runID, sessionID: runID, connection,
      apiKey: "secret-for-test", prompt: "请求工具", tools: ["open_ai_page"], limits: { maxRequests: 1 }, ephemeral: true } });
    const request = (await waitFor(m => m.params?.runID === runID && m.params.type === "tool_request")).params.toolRequest;
    send({ jsonrpc: "2.0", id: `limit-result-${attempt}`, method: "toolResult", params: { runID, requestID: request.requestID, text: "页面标识 fixture" } });
    assert.match((await waitFor(m => m.params?.runID === runID && m.params.type === "error")).params.message, /次数上限/);
    assert.equal(requests.length, before + 1, `attempt ${attempt} sent an extra model request`);
  }
  send({ jsonrpc: "2.0", id: 18, method: "run", params: { runID: "deadline", sessionID: "deadline", connection,
    apiKey: "secret-for-test", prompt: "取消测试", limits: { maxActiveMs: 100 } } });
  assert.match((await waitFor((m) => m.params?.runID === "deadline" && m.params.type === "error")).params.message, /执行时间上限/);
  send({ jsonrpc: "2.0", id: 19, method: "run", params: { runID: "permission", sessionID: "permission", connection,
    apiKey: "secret-for-test", prompt: "申请授权", tools: ["request_user_page"], limits: { maxActiveMs: 300 } } });
  const permission = (await waitFor((m) => m.params?.runID === "permission" && m.params.type === "tool_request")).params.toolRequest;
  await delay(500);
  assert.ok(!messages.some((m) => m.params?.runID === "permission" && m.params.type === "error"));
  send({ jsonrpc: "2.0", id: 20, method: "toolResult", params: { runID: "permission", requestID: permission.requestID, text: "页面标识 fixture" } });
  assert.equal((await waitFor((m) => m.params?.runID === "permission" && ["completed", "error"].includes(m.params.type))).params.type, "completed");
  send({ jsonrpc: "2.0", id: "submit-wait", method: "run", params: { runID: "submit-wait", sessionID: "submit-wait", connection,
    apiKey: "secret-for-test", prompt: "申请提交", tools: ["submit_ai_form"], limits: { maxActiveMs: 300 } } });
  const submission = (await waitFor(m => m.params?.runID === "submit-wait" && m.params.type === "tool_request")).params.toolRequest;
  assert.equal(submission.arguments.reference, "test-ref");
  await delay(500);
  assert.ok(!messages.some(m => m.params?.runID === "submit-wait" && m.params.type === "error"));
  send({ jsonrpc: "2.0", id: "submit-result", method: "toolResult", params: { runID: "submit-wait", requestID: submission.requestID, text: "页面标识 fixture" } });
  assert.equal((await waitFor(m => m.params?.runID === "submit-wait" && ["completed", "error"].includes(m.params.type))).params.type, "completed");
  send({ jsonrpc: "2.0", id: "button-wait", method: "run", params: { runID: "button-wait", sessionID: "button-wait", connection,
    apiKey: "secret-for-test", prompt: "申请按钮", tools: ["click_ai_button"], limits: { maxActiveMs: 300 } } });
  const buttonRequest = (await waitFor(m => m.params?.runID === "button-wait" && m.params.type === "tool_request")).params.toolRequest;
  assert.equal(buttonRequest.arguments.reference, "test-ref");
  await delay(500);
  assert.ok(!messages.some(m => m.params?.runID === "button-wait" && m.params.type === "error"));
  send({ jsonrpc: "2.0", id: "button-result", method: "toolResult", params: { runID: "button-wait", requestID: buttonRequest.requestID, text: "页面标识 fixture" } });
  assert.equal((await waitFor(m => m.params?.runID === "button-wait" && ["completed", "error"].includes(m.params.type))).params.type, "completed");
  send({ jsonrpc: "2.0", id: 25, method: "run", params: { runID: "login-wait", sessionID: "login-wait", connection,
    apiKey: "secret-for-test", prompt: "等待验证", tools: ["wait_for_login"], limits: { maxActiveMs: 300 } } });
  const login = (await waitFor((m) => m.params?.runID === "login-wait" && m.params.type === "tool_request")).params.toolRequest;
  assert.equal(login.arguments.tabID, "test-tab");
  await delay(500);
  assert.ok(!messages.some((m) => m.params?.runID === "login-wait" && m.params.type === "error"));
  send({ jsonrpc: "2.0", id: 26, method: "toolResult", params: { runID: "login-wait", requestID: login.requestID, text: "页面标识 fixture" } });
  assert.equal((await waitFor((m) => m.params?.runID === "login-wait" && ["completed", "error"].includes(m.params.type))).params.type, "completed");
  send({ jsonrpc: "2.0", id: 21, method: "run", params: { runID: "model-timeout", sessionID: "model-timeout", connection: { ...connection, timeout: 0.1 },
    apiKey: "secret-for-test", prompt: "取消测试", limits: { maxActiveMs: 3000 } } });
  assert.match((await waitFor((m) => m.params?.runID === "model-timeout" && m.params.type === "error")).params.message, /模型请求超时/);
  for (const [id, kind] of [[31, "openai-chat"], [32, "openai-responses"], [33, "anthropic-messages"]]) {
    const marker = `!literal-$HOME-${kind}`;
    send({ jsonrpc: "2.0", id, method: "run", params: { runID: `headers-${kind}`, sessionID: `headers-${kind}`,
      connection: { ...connection, id: `headers-${kind}`, kind }, apiKey: "secret-for-test", headers: { "X-Fixture": marker }, prompt: "测试协议" } });
    assert.equal((await waitFor((m) => m.params?.runID === `headers-${kind}` && ["completed", "error"].includes(m.params.type))).params.type, "completed");
    assert.equal(requests.at(-1).custom, marker);
    assert.ok(!JSON.stringify(messages).includes(marker));
  }
  for (const kind of ["openai-chat", "openai-responses", "anthropic-messages"]) {
    for (const failure of ["限流", "故障"]) {
      const runID = `retry-${kind}-${failure}`;
      const before = requests.length;
      send({ jsonrpc: "2.0", id: runID, method: "run", params: { runID, sessionID: runID,
        connection: { ...connection, id: runID, kind }, apiKey: "secret-for-test",
        prompt: `预算重试回归 ${failure}`, limits: { maxRequests: 1 }, ephemeral: true } });
      assert.equal((await waitFor(m => m.params?.runID === runID && ["completed", "error"].includes(m.params.type))).params.type, "error");
      assert.equal(requests.length, before + 1, `${runID} retried without a new reservation`);
      const usage = messages.filter(m => m.params?.runID === runID && m.params.type === "usage_progress").at(-1)?.params;
      assert.equal(usage?.modelRequests, 1);
      assert.equal(usage?.estimatedUsage, true);
      assert.ok(usage.accountedTokens > 0);
    }
  }
  send({ jsonrpc: "2.0", id: 34, method: "run", params: { runID: "bad-headers", sessionID: "bad-headers", connection,
    apiKey: "secret-for-test", headers: { "X-Fixture": "bad\r\nheader" }, prompt: "测试" } });
  assert.equal((await waitFor((m) => m.id === 34)).error.code, -32602);
  const beforeRedirect = requests.length;
  send({ jsonrpc: "2.0", id: 35, method: "run", params: { runID: "redirect", sessionID: "redirect", connection: { ...connection, baseURL: `http://127.0.0.1:${server.address().port}/redirect/v1` },
    apiKey: "secret-for-test", headers: { "X-Fixture": "redirect-fixture" }, prompt: "测试" } });
  assert.equal((await waitFor((m) => m.params?.runID === "redirect" && ["completed", "error"].includes(m.params.type))).params.type, "error");
  assert.equal(requests.length, beforeRedirect + 1);
  send({ jsonrpc: "2.0", id: 4, method: "closeSession", params: { sessionID: "session" } });
  assert.equal((await waitFor((m) => m.id === 4)).result.closed, true);
  console.log("Pi runtime: framed transport, streaming, credentials, multi-turn session, cancellation and hosted tool passed");
} finally {
  child.stdin.end();
  server.close();
}
