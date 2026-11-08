import { createServer } from "node:http";

let submissions = 0;
const server = createServer(async (request, response) => {
  const url = new URL(request.url, "http://localhost");
  if (url.pathname === "/tone.wav") {
    const rate = 8000, samples = rate * 2;
    const wave = Buffer.alloc(44 + samples * 2);
    wave.write("RIFF", 0); wave.writeUInt32LE(wave.length - 8, 4); wave.write("WAVEfmt ", 8);
    wave.writeUInt32LE(16, 16); wave.writeUInt16LE(1, 20); wave.writeUInt16LE(1, 22);
    wave.writeUInt32LE(rate, 24); wave.writeUInt32LE(rate * 2, 28); wave.writeUInt16LE(2, 32);
    wave.writeUInt16LE(16, 34); wave.write("data", 36); wave.writeUInt32LE(samples * 2, 40);
    for (let n = 0; n < samples; n++) wave.writeInt16LE(Math.round(Math.sin(2 * Math.PI * 440 * n / rate) * 32), 44 + n * 2);
    response.writeHead(200, { "content-type": "audio/wav", "content-length": wave.length }).end(wave);
    return;
  }
  if (url.pathname === "/media") {
    response.writeHead(200, { "content-type": "text/html; charset=utf-8" }).end(`<!doctype html><html><head><title>网页声音验收</title>
      <style>body{margin:28px;font:18px -apple-system;line-height:1.7;background:#f5f3ed;color:#28323e}h1{font-size:28px}button{font:inherit}</style></head><body>
      <h1>网页声音验收</h1><p>播放器继续运行，工具栏单独控制此标签的声音。</p>
      <audio id="player" src="/tone.wav" loop controls></audio><p id="state">等待播放</p>
      <script>const player = document.querySelector('audio'); player.addEventListener('playing', () => document.querySelector('#state').textContent='音频正在播放');
      window.startTone = async () => { window.context = new AudioContext(); const createGain=context.createGain.bind(context);window.createdGains=[];
        context.createGain=() => {const node=createGain();createdGains.push(node);return node;};window.oscillator = context.createOscillator(); oscillator.frequency.value=440;
        const level=context.createGain();level.gain.value=0.001;oscillator.connect(level);level.connect(context.destination);oscillator.start();await context.resume(); };
      ${url.searchParams.has("autoplay") ? "player.autoplay=true;player.play().catch(()=>{});" : ""}</script></body></html>`);
    return;
  }
  if (url.pathname === "/media-frame") {
    response.writeHead(200, { "content-type": "text/html; charset=utf-8" }).end(`<!doctype html><html><body><h1>内嵌播放器</h1>
      <iframe src="http://localhost:${server.address().port}/media?autoplay=1"></iframe></body></html>`);
    return;
  }
  if (url.pathname === "/device-article") {
    const agent = JSON.stringify(request.headers["user-agent"] || "").replaceAll("<", "\\u003c");
    const cookie = JSON.stringify(request.headers.cookie || "").replaceAll("<", "\\u003c");
    response.writeHead(200, { "content-type": "text/html; charset=utf-8", "set-cookie": "layout-session=fixture; Path=/; SameSite=Lax" }).end(`<!doctype html><html><head><title>自适应阅读</title>
      ${url.searchParams.has("viewport") ? '<meta name="viewport" content="width=700, initial-scale=0.8">' : ""}
      <style>body{margin:24px;font:18px -apple-system,sans-serif;line-height:1.7;background:#f7f5f0;color:#28323e}article{max-width:820px}h1{font-size:28px}#details{color:#657384}input{font:inherit;width:90%}.space{height:1600px}</style>
      </head><body><article><h1>自适应阅读</h1><p id="style"></p><p id="details"></p><label>阅读笔记<input aria-label="阅读笔记"></label><p>旋转或调整浏览区不会刷新正文。通过工具栏切换浏览版本。</p><div class="space"></div><p>文章结尾</p></article>
      <script>window.receivedAgent=${agent};window.receivedCookie=${cookie};document.querySelector('#style').textContent=receivedAgent.includes('iPhone')?'手机版原文':'电脑版原文';document.querySelector('#details').textContent='浏览宽度 '+innerWidth+'，高度 '+innerHeight;</script></body></html>`);
    return;
  }
  if (url.pathname === "/input-search") {
    response.writeHead(200, { "content-type": "text/html; charset=utf-8" }).end(`<!doctype html><html><head><title>站内搜索</title></head><body>
      <form action="/write"><label>站内搜索<input type="search" name="q"></label><button>搜索</button></form>
      <input type="password" aria-label="密码"><input autocomplete="one-time-code" aria-label="验证码"><input type="file">
      <input type="hidden" name="token" value="fixture-private"><textarea name="private_token">fixture-private</textarea>
      <input name="card_number"><input autocomplete="username"><input name="email"><input name="cvv">
      <label>验证码<input name="code"></label><label>密码<input name="credential"></label>
      <span id="billing">支付验证</span><input aria-labelledby="billing" name="data">
      <article id="result">等待查询</article><script>document.querySelector('input[type=search]').addEventListener('input', event => {
        document.querySelector('#result').textContent = '输入事件已收到：' + event.target.value;
      });</script></body></html>`);
    return;
  }
  if (url.pathname === "/nested-scroll-article") {
    response.writeHead(200, { "content-type": "text/html; charset=utf-8" }).end(`<!doctype html><html><head><title>内层滚动报道</title>
      <style>body{margin:0;overflow:hidden}#reader{height:420px;overflow-y:auto}article{min-height:2400px}</style></head><body>
      <header>固定工具栏</header><div id="reader"><article><p>内层正文</p><div style="height:2000px"></div></article></div>
      <script>document.querySelector('#reader').addEventListener('scroll', event => {
        if (event.target.scrollTop > 100 && !document.querySelector('#loaded')) {
          const text = document.createElement('p'); text.id = 'loaded'; text.textContent = '内层滚动后加载的正文'; document.querySelector('article').append(text);
        }
      });</script></body></html>`);
    return;
  }
  if (url.pathname === "/scroll-article") {
    response.writeHead(200, { "content-type": "text/html; charset=utf-8" }).end(`<!doctype html><html><head><title>滚动报道</title>
      <style>body{margin:0}main{min-height:2400px}#spacer{height:2000px}</style></head><body><main>
      <a href="/article">相关报道</a><p>滚动前的正文</p><div id="spacer"></div></main>
      <script>addEventListener('scroll', () => { if (scrollY > 100 && !document.querySelector('#loaded')) {
        const text = document.createElement('p'); text.id = 'loaded'; text.textContent = '滚动后加载的正文'; document.querySelector('main').append(text);
      }});</script></body></html>`);
    return;
  }
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
    if (payload.messages.some(message => JSON.stringify(message.content).includes("研究滚动页面"))) {
      const page = history.map(message => String(message.content)).join('\n').match(/[0-9A-F]{8}(?:-[0-9A-F]{4}){3}-[0-9A-F]{12}/i)?.[0];
      const name = ["open_ai_page", "scroll_ai_page", "read_ai_page"][history.length];
      const args = history.length === 0 ? {url: `http://127.0.0.1:${server.address().port}/scroll-article`} :
        history.length === 1 ? {tabID: page, direction: "down"} : {tabID: page};
      if (name) {
        delta = {role: "assistant", tool_calls: [{index: 0, id: `scroll-${history.length}`, type: "function", function: {name, arguments: JSON.stringify(args)}}]};
        finish = "tool_calls";
      } else {
        delta = {role: "assistant", content: String(history.at(-1)?.content).includes("滚动后加载的正文") ? "已阅读滚动后加载的正文 [E1]" : "研究失败。"};
        finish = "stop";
      }
      response.writeHead(200, {"content-type": "text/event-stream"});
      for (const [part, reason] of [[delta, null], [{}, finish]]) response.write(`data: ${JSON.stringify({id: "fixture", object: "chat.completion.chunk", created: 1, model: "mock", choices: [{index: 0, delta: part, finish_reason: reason}]})}\n\n`);
      response.end("data: [DONE]\n\n");
      return;
    }
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
  if (url.pathname === "/search-containers") {
    const engine = url.searchParams.get("engine");
    const result = (id, hidden = false) => {
      const title = `搜索报道${id}`;
      const style = hidden ? ' style="display:none"' : '';
      if (engine === "google") return `<div class="MjjYud"${style}><a href="/article?id=${id}"><h3>${title}</h3></a><div class="VwiC3b">报道摘要${id}</div></div>`;
      if (engine === "baidu") return `<div class="result"${style}><h3><a href="/article?id=${id}">${title}</a></h3><div class="c-abstract">报道摘要${id}</div></div>`;
      return `<li class="b_algo"${style}><h2><a href="/article?id=${id}">${title}</a></h2><div class="b_caption"><p>报道摘要${id}</p></div></li>`;
    };
    const empty = engine === "google" ? '<div class="MjjYud">搜索布局</div>' : engine === "baidu" ? '<div class="result">搜索布局</div>' : '<li class="b_algo">搜索布局</li>';
    const results = Array.from({ length: 12 }, (_, i) => result(i + 1)).join("");
    const content = empty.repeat(12) + result("hidden", true) + result(1) + results;
    const body = engine === "google" ? `<div id="search"><div class="MjjYud">${content}</div></div>` : engine === "baidu" ? `<div id="content_left">${content}</div>` : `<ol>${content}</ol>`;
    response.writeHead(200, { "content-type": "text/html; charset=utf-8" }).end(`<!doctype html><html><body>${body}</body></html>`);
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
