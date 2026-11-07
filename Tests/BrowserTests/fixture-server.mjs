import { createServer } from "node:http";

let submissions = 0;
const server = createServer(async (request, response) => {
  const url = new URL(request.url, "http://localhost");
  if (url.pathname === "/slow") {
    await new Promise(resolve => setTimeout(resolve, 4000));
    if (!response.destroyed) response.writeHead(200, { "content-type": "text/html; charset=utf-8" }).end("<html><body>延迟页面</body></html>");
    return;
  }
  if (/^\/status\/(401|403|429|500)$/.test(url.pathname)) {
    const status = Number(url.pathname.split("/").at(-1));
    response.writeHead(status, { "content-type": "text/html; charset=utf-8" }).end('<!doctype html><html><body><article>错误页面不应成为证据</article></body></html>');
    return;
  }
  if (url.pathname === "/redirect") {
    response.writeHead(302, { location: "/write" }).end();
    return;
  }
  if (url.pathname === "/frames") {
    response.writeHead(200, { "content-type": "text/html; charset=utf-8" }).end('<!doctype html><html><body><article>主页面报道内容</article><iframe src="about:blank"></iframe><iframe src="/status/403"></iframe></body></html>');
    return;
  }
  if (url.pathname === "/approval-form") {
    response.writeHead(200, { "content-type": "text/html; charset=utf-8" }).end(`<!doctype html><html><body>
      <form method="post" action="/write?draft=example"><label>内容<input name="content" value="待确认内容"></label>
      <input type="hidden" name="csrf" value="fixture-hidden-token"><button id="submit">发布</button></form>
      <form method="post" action="/write"><input type="password" name="password"><button>登录</button></form>
      </body></html>`);
    return;
  }
  if (url.pathname === "/approval-get") {
    response.writeHead(200, { "content-type": "text/html; charset=utf-8" }).end(`<!doctype html><html><body>
      <form method="get" action="/write"><input name="topic" value="news"><button>提交查询</button></form>
      </body></html>`);
    return;
  }
  if (url.pathname === "/approval-get-unicode") {
    response.writeHead(200, { "content-type": "text/html; charset=utf-8" }).end(`<!doctype html><html><body>
      <form method="get" action="/write"><input name="词" value="中文 + 内容"><input name="词" value="second"><button name="go" value="yes">提交查询</button></form>
      </body></html>`);
    return;
  }
  if (url.pathname === "/approval-multipart") {
    response.writeHead(200, { "content-type": "text/html; charset=utf-8" }).end(`<!doctype html><html><body>
      <form method="post" enctype="multipart/form-data" action="/write"><input name="topic" value="news"><button>提交</button></form>
      </body></html>`);
    return;
  }
  if (url.pathname === "/approval-button") {
    response.writeHead(200, { "content-type": "text/html; charset=utf-8" }).end(`<!doctype html><html><body>
      <button id="publish" onclick="fetch('/write', {method:'POST'})">发布更新</button>
      <button disabled>不可用</button><form><button>表单按钮</button></form>
      </body></html>`);
    return;
  }
  if (url.pathname === "/disclosure-background-write") {
    response.writeHead(200, { "content-type": "text/html; charset=utf-8" }).end(`<!doctype html><html><body>
      <article>测试报道</article><details ontoggle="if(this.open) fetch('/write', {method:'POST'})"><summary>展开正文</summary>后续报道</details>
      </body></html>`);
    return;
  }
  if (url.pathname === "/responsive") {
    response.writeHead(200, { "content-type": "text/html; charset=utf-8" }).end('<!doctype html><html><head><style>.desktop{display:none}@media(min-width:700px){.desktop{display:block}}</style></head><body><article><div class="desktop">桌面视口中的报道</div></article></body></html>');
    return;
  }
  if (url.pathname === "/delayed-article") {
    response.writeHead(200, { "content-type": "text/html; charset=utf-8" }).end(`<!doctype html><html><head><title>动态报道</title></head><body><main></main>
      <script>setTimeout(() => { document.querySelector('main').innerHTML = '<article><p>延迟加载的报道正文</p></article>'; }, 1300);</script></body></html>`);
    return;
  }
  if (url.pathname === "/sensitive") {
    response.writeHead(200, { "content-type": "text/html; charset=utf-8" }).end(`<!doctype html><html><head><title>测试报道</title></head><body>
      <nav>导航区个人信息</nav><article style="display:none">不可见文章</article><article><h1>测试新闻标题</h1><p>这里是可引用的新闻正文。</p><span style="display:contents">可见的行内文字</span>
      <p style="display:none">不可见内容</p><div contenteditable="true">正在编辑的内容</div>
      <form><label>账户字段</label><textarea>输入区已有内容</textarea><button>提交</button></form>
      <details><summary>更多内容</summary>展开后的内容</details></article><aside>侧栏个人信息</aside></body></html>`);
    return;
  }
  if (url.pathname === "/hostile-extraction") {
    response.writeHead(200, { "content-type": "text/html; charset=utf-8" }).end(`<!doctype html><html><head><title>测试来源</title></head><body>
      <article><p>网页实际正文</p><details><summary>展开报道</summary>相关内容</details></article><a href="/article">下一篇报道</a>
      <script>JSON.stringify = () => '{"title":"伪造","text":"伪造的内容","loginRequired":false}';
      document.querySelector = () => null; document.querySelectorAll = () => []; window.getComputedStyle = () => ({visibility:'hidden'});</script>
      </body></html>`);
    return;
  }
  if (url.pathname === "/v1/chat/completions" && request.method === "POST") {
    let data = "";
    for await (const chunk of request) data += chunk;
    const payload = JSON.parse(data);
    const history = payload.messages.filter(message => message.role === "tool");
    let delta;
    let finish;
    if (payload.messages.some(message => JSON.stringify(message.content).includes("研究用户标签"))) {
      const result = history.length ? String(history.at(-1).content) : "";
      let name, args;
      if (history.length === 0) { name = "request_user_page"; args = { access: "operate", reason: "检查用户页面按钮" }; }
      else if (history.length === 1) { name = "observe_ai_page"; args = { tabID: result.match(/[0-9A-F]{8}(?:-[0-9A-F]{4}){3}-[0-9A-F]{12}/i)?.[0] }; }
      else if (history.length === 2) { name = "click_ai_button"; args = { reference: result.match(/网页按钮标识：([0-9A-F-]+)/i)?.[1] }; }
      if (name && Object.values(args).every(Boolean)) {
        delta = { role: "assistant", tool_calls: [{ index: 0, id: `user-${history.length}`, type: "function", function: { name, arguments: JSON.stringify(args) } }] };
        finish = "tool_calls";
      } else {
        delta = { role: "assistant", content: result.includes("核对") ? "请核对用户页面操作结果。" : "研究失败。" }; finish = "stop";
      }
      response.writeHead(200, { "content-type": "text/event-stream" });
      for (const [part, reason] of [[delta, null], [{}, finish]]) {
        response.write(`data: ${JSON.stringify({ id: "fixture", object: "chat.completion.chunk", created: 1, model: "mock", choices: [{ index: 0, delta: part, finish_reason: reason }] })}\n\n`);
      }
      response.end("data: [DONE]\n\n");
      return;
    }
    if (payload.messages.some(message => JSON.stringify(message.content).includes("研究表单确认"))) {
      const result = history.length ? String(history.at(-1).content) : "";
      let name, args;
      if (history.length === 0) {
        name = "open_ai_page"; args = { url: `http://127.0.0.1:${server.address().port}/approval-form` };
      } else if (history.length === 1) {
        name = "observe_ai_page"; args = { tabID: result.match(/[0-9A-F]{8}(?:-[0-9A-F]{4}){3}-[0-9A-F]{12}/i)?.[0] };
      } else if (history.length === 2) {
        name = "submit_ai_form"; args = { reference: result.match(/页面操作标识：([0-9A-F-]+)/i)?.[1] };
      }
      if (name && Object.values(args).every(Boolean)) {
        delta = { role: "assistant", tool_calls: [{ index: 0, id: `call-${history.length}`, type: "function", function: { name, arguments: JSON.stringify(args) } }] };
        finish = "tool_calls";
      } else {
        delta = { role: "assistant", content: result.includes("拒绝") ? "用户拒绝了提交。" : result.includes("核对") ? "请核对提交结果。" : "研究失败。" };
        finish = "stop";
      }
      response.writeHead(200, { "content-type": "text/event-stream" });
      for (const [part, reason] of [[delta, null], [{}, finish]]) {
        response.write(`data: ${JSON.stringify({ id: "fixture", object: "chat.completion.chunk", created: 1, model: "mock", choices: [{ index: 0, delta: part, finish_reason: reason }] })}\n\n`);
      }
      response.end("data: [DONE]\n\n");
      return;
    }
    if (history.length === 0) {
      const currentStory = payload.messages.some(message => JSON.stringify(message.content).includes("研究当前原文"));
      delta = { role: "assistant", tool_calls: [{ index: 0, id: "open", type: "function", function: {
        name: currentStory ? "open_current_story" : "open_ai_page", arguments: JSON.stringify(currentStory ? {} : { url: `http://127.0.0.1:${server.address().port}/article` }) } }] };
      finish = "tool_calls";
    } else if (history.length === 1) {
      const tabID = JSON.stringify(history[0]).match(/[0-9A-F]{8}(?:-[0-9A-F]{4}){3}-[0-9A-F]{12}/i)?.[0];
      if (!tabID) { response.writeHead(500).end(); return; }
      delta = { role: "assistant", tool_calls: [{ index: 0, id: "read", type: "function", function: {
        name: "read_ai_page", arguments: JSON.stringify({ tabID }) } }] };
      finish = "tool_calls";
    } else {
      const result = JSON.stringify(history.at(-1));
      delta = { role: "assistant", content: result.includes("登录后可见的文章正文") && result.includes("[E1]") ? "已阅读登录文章 [E1]" : "读取失败" };
      finish = "stop";
    }
    response.writeHead(200, { "content-type": "text/event-stream" });
    for (const [part, reason] of [[delta, null], [{}, finish]]) {
      response.write(`data: ${JSON.stringify({ id: "fixture", object: "chat.completion.chunk", created: 1, model: "mock", choices: [{ index: 0, delta: part, finish_reason: reason }] })}\n\n`);
    }
    response.end("data: [DONE]\n\n");
    return;
  }
  if (url.pathname === "/write") submissions++;
  if (url.pathname === "/stats") {
    response.writeHead(200, { "content-type": "application/json" }).end(JSON.stringify({ submissions }));
    return;
  }
  if (url.pathname === "/search-result") {
    response.writeHead(200, { "content-type": "text/html; charset=utf-8" }).end('<!doctype html><html><body><ol><li class="b_algo"><h2><a href="/article">测试搜索结果</a></h2><div class="b_caption"><p>搜索摘要</p></div></li></ol></body></html>');
    return;
  }
  if (url.pathname === "/baidu-safety") {
    response.writeHead(200, { "content-type": "text/html; charset=utf-8" }).end('<!doctype html><html><head><title>百度安全验证</title></head><body>网络不给力，请稍后重试</body></html>');
    return;
  }
  const authenticated = (request.headers.cookie ?? "").includes("test_session=fixture");
  const title = url.pathname === "/login" ? "测试登录" : "测试文章";
  const text = url.pathname === "/long" ? "甲".repeat(9000) + "终点" : url.pathname === "/login" ? "已建立测试登录状态" : authenticated ? "登录后可见的文章正文" : "游客内容";
  const headers = { "content-type": "text/html; charset=utf-8" };
  if (url.pathname === "/login") headers["set-cookie"] = "test_session=fixture; Path=/; Max-Age=3600; HttpOnly; SameSite=Lax";
  const challenge = url.pathname === "/challenge" ? '<input type="password" placeholder="登录">' :
    (url.pathname === "/captcha" ? '<div data-sitekey="fixture" style="width:100px;height:100px">验证</div>' :
      (url.pathname === "/qr" ? '<div>扫码登录</div><canvas width="100" height="100"></canvas>' : ""));
  response.writeHead(200, headers).end(`<!doctype html><html><head><title>${title}</title></head><body><article style="min-height:4000px">${text}</article><a id="next" href="/long?page=2">下一页</a><details><summary>展开更多内容</summary>展开后的正文</details>${challenge}<form method="post" action="/write?draft=example"><button id="submit">提交</button></form></body></html>`);
});
server.listen(0, "127.0.0.1", () => console.log(server.address().port));
