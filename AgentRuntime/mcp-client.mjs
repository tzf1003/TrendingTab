import { McpClient, StdioTransport, StreamableHttpTransport } from "@earendil-works/pi-mcp";
import { isAbsolute } from "node:path";

const MAX_MESSAGE = 1024 * 1024;
const MAX_ARGUMENTS = 64 * 1024;
const MAX_RESULT = 100 * 1024;

function checkAbort(signal) {
  if (signal?.aborted) throw new DOMException("Task cancelled", "AbortError");
}

function abortable(promise, signal) {
  if (signal.aborted) return Promise.reject(new DOMException("Task cancelled", "AbortError"));
  return new Promise((resolve, reject) => {
    const abort = () => reject(new DOMException("Task cancelled", "AbortError"));
    signal.addEventListener("abort", abort, { once: true });
    Promise.resolve(promise).then(resolve, reject).finally(() => signal.removeEventListener("abort", abort));
  });
}

// This client is application-owned. It never discovers MCP configuration from disk.
// The host must supply an explicit enabled-tool set and authorize every invocation.
export class ManagedMcpConnection {
  #client;
  #enabled;
  #tools = new Map();
  #authorize;
  #transport;
  #closed = false;
  #controllers = new Set();
  #discoverOnly;

  constructor(config, enabledTools, authorize, { discoverOnly = false } = {}) {
    if (!config || !Array.isArray(enabledTools) || enabledTools.length > 100 ||
        enabledTools.some(name => typeof name !== "string" || !name || name.length > 256) ||
        new Set(enabledTools).size !== enabledTools.length || typeof authorize !== "function") {
      throw new TypeError("Invalid MCP configuration");
    }
    this.#enabled = new Set(enabledTools);
    this.#discoverOnly = discoverOnly;
    this.#authorize = authorize;
    this.#client = new McpClient({ name: "TrendingTab", version: "0.1.0", requestTimeoutMs: 30000 });
    if (config.type === "stdio") {
      if (typeof config.command !== "string" || !isAbsolute(config.command) ||
          !Array.isArray(config.args) || config.args.length > 100 ||
          config.args.some(arg => typeof arg !== "string" || arg.length > 4096) ||
          (config.cwd != null && (typeof config.cwd !== "string" || !isAbsolute(config.cwd))) ||
          !validStrings(config.env ?? {}, 100)) throw new TypeError("Invalid MCP process configuration");
      this.#transport = new StdioTransport({ command: config.command, args: [...config.args], cwd: config.cwd,
        env: { ...config.env }, inheritEnv: false, stderr: "pipe", maxMessageBytes: MAX_MESSAGE });
    } else if (config.type === "http") {
      let url;
      try { url = new URL(config.url); } catch { throw new TypeError("Invalid MCP URL"); }
      if (!["https:", "http:"].includes(url.protocol) || url.username || url.password || url.hash ||
          !validHeaders(config.headers ?? {})) throw new TypeError("Invalid MCP HTTP configuration");
      this.#transport = new StreamableHttpTransport({ url, headers: { ...config.headers }, openGetStream: false,
        maxMessageBytes: MAX_MESSAGE, fetch: (input, options) => fetch(input, { ...options, redirect: "error" }) });
    } else throw new TypeError("Unsupported MCP transport");
  }

  async connect() {
    if (this.#closed) throw new Error("MCP connection is closed");
    try {
      await this.#client.connect(this.#transport);
      const tools = await this.#client.listTools();
      if (this.#closed) throw new Error("MCP connection is closed");
      if (tools.length > 1000 || new Set(tools.map(tool => tool.name)).size !== tools.length) {
        throw new Error("Invalid MCP tool list");
      }
      this.#tools = new Map(tools.filter(tool => !this.#discoverOnly && this.#enabled.has(tool.name)).map(tool => [tool.name, tool]));
      return this.#discoverOnly ? tools : [...this.#tools.values()];
    } catch (error) {
      await this.close();
      throw error;
    }
  }

  async call(name, args, { runID, signal } = {}) {
    checkAbort(signal);
    if (this.#closed || !this.#tools.has(name) || typeof runID !== "string" || !runID ||
        !args || typeof args !== "object" || Array.isArray(args)) throw new Error("MCP tool is unavailable");
    const encoded = JSON.stringify(args);
    if (Buffer.byteLength(encoded) > MAX_ARGUMENTS) throw new Error("MCP tool arguments exceed limit");
    const callArguments = JSON.parse(encoded);
    const controller = new AbortController();
    this.#controllers.add(controller);
    const abort = () => controller.abort();
    signal?.addEventListener("abort", abort, { once: true });
    try {
      checkAbort(signal);
      // Server annotations are untrusted; the host applies its own confirmation policy.
      const allowed = await abortable(this.#authorize({ runID, name, arguments: structuredClone(callArguments), signal: controller.signal }), controller.signal);
      checkAbort(controller.signal);
      if (this.#closed || allowed !== true) throw new Error("MCP tool permission denied");
      const result = await this.#client.callTool(name, callArguments, { signal: controller.signal, timeoutMs: 30000 });
      checkAbort(controller.signal);
      if (Buffer.byteLength(JSON.stringify(result)) > MAX_RESULT) throw new Error("MCP tool result exceeds limit");
      return result;
    } finally {
      signal?.removeEventListener("abort", abort);
      this.#controllers.delete(controller);
    }
  }

  async close() {
    if (this.#closed) return;
    this.#closed = true;
    this.#tools.clear();
    for (const controller of this.#controllers) controller.abort();
    await this.#client.close();
  }
}

function validStrings(values, max) {
  return values && typeof values === "object" && !Array.isArray(values) &&
    Object.entries(values).length <= max && Object.entries(values).every(([key, value]) =>
      key.length > 0 && key.length <= 256 && !/[\0\r\n]/.test(key) &&
      typeof value === "string" && value.length <= 4096 && !/[\0\r\n]/.test(value));
}

function validHeaders(headers) {
  if (!validStrings(headers, 20)) return false;
  const names = new Set();
  const reserved = new Set(["host", "content-length", "transfer-encoding", "connection", "cookie", "set-cookie", "proxy-authorization", "mcp-session-id", "mcp-protocol-version"]);
  return Object.keys(headers).every(name => {
    const key = name.toLowerCase();
    if (!/^[!#$%&'*+.^_`|~0-9A-Za-z-]+$/.test(name) || reserved.has(key) || names.has(key)) return false;
    names.add(key);
    return /^[\x09\x20-\x7e]*$/.test(headers[name]);
  });
}
