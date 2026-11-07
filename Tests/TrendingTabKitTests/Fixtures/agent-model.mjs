import { createServer } from "node:http";

const server = createServer(async (request, response) => {
  let data = "";
  for await (const part of request) data += part;
  const body = JSON.parse(data);
  if (request.url !== "/v1/chat/completions" || request.headers.authorization !== "Bearer fixture-token") {
    response.writeHead(401).end();
    return;
  }
  const serialized = JSON.stringify(body.messages);
  if (serialized.includes("等待用量")) {
    response.writeHead(200, { "content-type": "text/event-stream" });
    response.flushHeaders();
    return;
  }
  if (serialized.includes("调用工具") || serialized.includes("请调用 open_ai_page 工具") || serialized.includes("调用MCP")) {
    response.writeHead(200, { "content-type": "text/event-stream" });
    const finished = body.messages.some((message) => message.role === "tool");
    const mcp = serialized.includes("调用MCP");
    const delta = finished
      ? { role: "assistant", content: serialized.includes("来自原生端") || serialized.includes("连接测试已收到工具调用") || (mcp && serialized.includes("mcp-evidence")) ? (serialized.includes("调用工具并引用") ? "工具完成 [E1]" : "工具完成") : "结果错误" }
      : { role: "assistant", tool_calls: [{ index: 0, id: "fixture-call", type: "function",
          function: mcp ? { name: "mcp_call_tool", arguments: JSON.stringify({ serverID: "fixture", toolName: "echo", argumentsJSON: JSON.stringify({ value: "mcp-evidence" }) }) }
            : { name: "open_ai_page", arguments: '{"url":"https://example.com/"}' } }] };
    const send = (value) => response.write(`data: ${JSON.stringify(value)}\n\n`);
    send({ id: "mock", object: "chat.completion.chunk", created: 1, model: "mock",
      choices: [{ index: 0, delta, finish_reason: null }] });
    send({ id: "mock", object: "chat.completion.chunk", created: 1, model: "mock",
      choices: [{ index: 0, delta: {}, finish_reason: finished ? "stop" : "tool_calls" }] });
    response.end("data: [DONE]\n\n");
    return;
  }
  const conversation = body.messages.filter((message) => ["user", "assistant"].includes(message.role));
  const hasHistory = serialized.includes("第二问") && serialized.includes("第一问");
  const result = serialized.includes("追问证据") ?
    (serialized.includes("先前研究证据") && serialized.includes("[E1]") ? "证据已传递" : "证据缺失") :
    serialized.includes("材料为以下 JSON 数组：") ?
      (serialized.includes("用于自动摘要的公开正文") ? '{"summary":"基于正文的摘要","evidenceIDs":["fixture:1"]}' : "原文材料缺失") :
    serialized.includes("主题描述：") ? '{"matchedIDs":["fixture:1"]}' :
    serialized.includes("检查请求头") ? (request.headers["x-fixture"] === "!literal-$HOME" ? "请求头正确" : "请求头错误") :
    (serialized.includes("请只输出 JSON 对象") ? '{"ok":true}' : (hasHistory ? (conversation.map((message) => message.role).join(",") === "user,assistant,user" ? "连续对话" : "角色错误") : "测试回答"));
  response.writeHead(200, { "content-type": "text/event-stream" });
  for (const [delta, finish] of [[{ role: "assistant", content: result }, null], [{}, "stop"]]) {
    response.write(`data: ${JSON.stringify({ id: "mock", object: "chat.completion.chunk", created: 1,
      model: "mock", choices: [{ index: 0, delta, finish_reason: finish }],
      ...(finish ? { usage: { prompt_tokens: 12, completion_tokens: 3, total_tokens: 15 } } : {}) })}\n\n`);
  }
  response.end("data: [DONE]\n\n");
});
server.listen(0, "127.0.0.1", () => console.log(server.address().port));
