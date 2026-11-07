# 内置浏览器与 Pi Agent 验收清单

本清单覆盖浏览器与站点身份、Pi 模型与工具、自动任务、Runtime 更新及 macOS 分发。代码、模拟测试、真实站点及发布制品分别作为证据；记录为“待验收”的条目需要补齐对应环境中的实际结果。

最近已验收的正式版为 [v0.2.45](https://github.com/tzf1003/TrendingTab/releases/tag/v0.2.45)，随包 Runtime 0.1.5、Pi 1.5.0。[CI 42354687049](https://github.com/tzf1003/TrendingTab/actions/runs/42354687049) 已通过签名、公证及 Intel 原生验证。详细日期、制品哈希、真实模型调用和限制见 [验证记录](verification.md)。

## 浏览器与站点身份

| 要求 | 当前实现与证据 | 验收状态 |
|---|---|---|
| 中栏原文浏览、导航、地址、阅读模式、外部打开 | `App/BrowserWorkspace.swift`；`testReaderKeepsLivePageAndClearsOnNavigation`；正式版原文及引用打开记录 | 已实现；基础流程已验收 |
| 保留 WebView、当前热点标签、固定标签、Command 新开 | `BrowserWorkspace.openStory`、`BrowserTabButton`、事件中心新闻点击路由 | 已实现；完整窗口交互需继续检查 |
| 用户／AI 两组标签与弹窗身份 | `testPopupOwnershipFollowsCurrentController`，预览与实际网页输入分别处理 | 自动回归及正式版预览通过 |
| 稳定持久网站存储、重启／升级后登录复用 | `WKWebsiteDataStore(forIdentifier:)`；`testNamedWebsiteStoreSharesLoginAcrossWorkspaceInstances`；知乎重启与应用内更新记录 | 知乎实际通过；其他站点按下表验收 |
| 管理、清除站点数据及共享身份说明 | 浏览器设置、`clearWebsiteData`，Cookie 与站点存储清理回归 | 已实现并有测试 |
| 登录、验证码、过期时等待与恢复 | `testCaptchaPageRequestsUserVerification`、`testLoginWaitRestoresResearchAndCancellation`、`testUserCanResumeBlockedPageWithoutNavigation` | 模拟流程通过；真实验证码由用户完成 |
| AI 后台保持用户标签 URL、焦点、位置 | `testSharedLoginAndBackgroundResearchRespectUserTab`、滚动回归；真实知乎预览与连续追问记录 | 自动回归及知乎实际通过 |
| 用户页本轮读／操作授权，接管／导航／结束后失效 | 用户授权、导航、会话结束、迟到工具请求和操作确认测试 | 自动回归通过 |
| AI 自主观察、读取、查找、滚动、展开、打开链接 | `BrowserToolBroker`、`tool-catalog.mjs`；整页与内层滚动；实际 Pi 工具链和知乎读取 | 自动回归及知乎实际通过 |
| 提交前具体确认 | 表单及网页按钮确认、字段变化、取消、接管、导航快照回归 | 显式工具操作通过；网页脚本边界见下文 |

## Pi、工具、对话与调度

| 要求 | 当前实现与证据 | 验收状态 |
|---|---|---|
| 独立进程、私有长度帧、运行 ID、流序号、取消和退出恢复 | `AgentBridge`、`runtime.mjs`；分包、重复序号、并发空闲读取、取消看门狗及恢复测试 | 已实现并有回归 |
| 独立配置与资源、按运行注入密钥、禁用默认 Shell 工具 | `runtime-resource-loader.mjs`、内存 `ModelRuntime`、明确工具目录、私有管道 | 已实现；Runtime 自检覆盖工具循环 |
| 三种模型协议、自定义根路径／请求头、流式、用量、错误及预算 | `AgentRuntime/test-runtime.mjs`、连接测试、Swift Pi 桥接回归 | 三协议模拟通过；实际已配置连接有研究记录 |
| 模型连接 ID、任务分配、Keychain 凭据保持 | 连接编辑及在途旧结果丢弃回归；应用更新后设置记录 | 已实现并有回归 |
| 直接回答／深度研究、连续追问、停止、重试、研究过程 | `AnalysisChat`、事件中心；知乎及公开微博多轮记录 | 已实现并有实际记录 |
| Brave／Tavily 与百度／Bing／Google 网页搜索 | `ResearchSearch`、匿名 API 会话、结果标准化、时间／站点筛选测试；Brave 新闻端点及 Tavily news 模式；Bing 实际结果打开记录 | 网页／新闻 API 模拟及部分网页实际通过；API 真实读取依赖服务凭据 |
| 公开匿名正文、分段、当前热点、证据登记与材料级别 | `PublicArticle`、`ResearchEvidence`、Broker；公网地址、分页、跨对话隔离回归 | 已实现并有回归 |
| 引用 ID、来源、获取时间、连续研究证据 | 事件中心来源按钮、证据账本；逐回答保存证据范围，停止、重试及实际 Pi 工具回归；v0.2.45 实际安装后生成有效引用 | 引用展示实际通过；跨轮未知编号隔离由自动回归验证 |
| MCP Streamable HTTP／stdio、独立配置、工具启用与授权 | `mcp-client.mjs`、设置与 Keychain；环境隔离、跨站重定向、取消、原生确认测试 | 已实现并有回归；外部服务依赖各自配置 |
| 分类、摘要、主题全部走 Pi | `AppModel`、`AgentAIProvider`，自动分析与主题公平轮询回归；自动摘要可选匿名读取最多 3 篇原文 | 已实现；原文摘要通过模拟模型、实际 Pi 子进程及数据库回归 |
| 前后台各一个任务、AI 两个并行加载、同标签串行 | `AgentTaskCoordinator`、Broker `busyTabs`、研究加载额度及取消回归 | 已实现并有回归 |
| 12 次模型请求、30 次工具、180 秒，授权时暂停计时 | `runtime.mjs`，三协议请求预算、最后回答、授权等待和取消测试 | 已实现并有回归 |
| 自动请求／token 持久预算、未知结果保守记账、手动用量分开 | SQLite AI 预留、自动任务缓存、用量测试和真实研究 UI | 已实现并有回归 |
| 当前热点过期、掉榜解除关联；会话／材料仅内存 | 数据清理、旧分析结果丢弃、窗口关闭与结束对话路径 | 已实现；窗口关闭交互需继续检查 |

## Runtime 与分发

| 要求 | 当前实现与证据 | 验收状态 |
|---|---|---|
| 随包 Node／Pi、版本独立、双架构 | `prepare-agent-runtime.sh`；实际 v0.2.45 制品及两架构健康检查 | 已通过 |
| 每日检查、用户安装、版本与兼容信息 | `AppModel.prepareRuntime`、每小时到期检查循环、Runtime 设置 | 已实现；实际界面更新有记录 |
| 发布哈希、Developer ID、票据、架构、系统／应用／协议验证 | `AgentRuntimeManifest`、Verifier、Installer；损坏、错误版本、未公证及能力缺失回归 | 已实现并有实际制品验证 |
| 新目录健康检查、原子切换、空闲启用、上一版／启动失败回退 | Runtime 安装、回退、取消、故障恢复回归；真实设置安装回退记录 | 已通过 |
| 签名公证应用 DMG、Widget 和独立 Runtime；Intel CI | 两份实际镜像哈希与发布资产一致；CI 构建、Intel、发布成功 | v0.2.45 已通过 |

## 真实站点与已确认边界

| 场景 | 已有证据 | 剩余验收 |
|---|---|---|
| 知乎应用内登录、重启与升级、原文、搜索、多轮、引用 | 登录持久性、已登录读取、前序搜索研究；v0.2.45 上下滚动、预览后追问及正文引用 | 在同一轮中重新完成搜索、比较和连续追问；记录模型超时与搜索跳转 |
| 微博 | 公开热搜页读取、搜索补充、新闻比较、引用打开、正式版预览后连续观察 | 应用内微博登录身份的完整研究 |
| 一个新闻站 | 公开澎湃页面及南都新闻正文读取、比较和来源打开 | 应用内新闻站登录身份的完整研究 |
| 抖音正文、视频、登录 | 一次实际热点仅提取导航文字，模型说明材料范围 | 在有效登录状态下重新记录正文／视频可读范围 |

用户已选择网站兼容优先：允许网页脚本运行。显式 AI 表单／按钮工具保留确认，网页脚本自己的后台请求可能绕过该确认，已有预期失败测试记录这个边界。AI 顶层导航的地址检查也不控制 WebKit DNS 和所有子资源，不能据此宣称完整网络隔离。

本机 Gatekeeper 评估显示系统安全检查被全局覆盖；本机签名、公证票据结果与 CI 中启用检查时的结果分别记录。真实登录、验证码和站点限制需要在对应站点当前环境下验收，模拟回归只证明本地控制流程。
