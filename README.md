# TrendingTab

TrendingTab 是一个 macOS 14+ 的热榜聚合应用。桌面小组件负责快速浏览，菜单栏负责刷新、暂停采集和打开设置，本地服务负责采集、聚合、AI 判断与提醒。

## 功能

- 事件中心按榜单热度排序，标签可直接点击并用两端箭头切换；列表只显示本次榜单和更新时间。
- 平台榜单、聚合、重大事件、主题和事件追踪使用同一级标签，可排序、隐藏和独立订阅提醒。
- 默认每 15 分钟采集，可设置为 5 至 1440 分钟。
- 首版接入 17 个来源，每个来源使用独立适配器。
- 三种 Widget 使用紧凑单行标题，长标题以省略号结尾。常规尺寸下小型显示 5 条，中型两列共 8 条，大型一列约 10 条。
- 每个组件可固定显示所选榜单，例如同时放置知乎组件与微博组件。可切换组件按尺寸、起始榜单和组件编号分别保存选择。
- 事件中心与设置使用统一的浅色、深色配色；组件采用暖色到雾蓝的柔和渐变背景。
- 设置页自动读取 GitHub 最新 Release，发现新版本后可下载并一键安装。
- 支持 OpenAI Responses、OpenAI Chat Completions 和 Anthropic Messages。
- 事件中心右侧提供独立 AI 对话栏，支持流式回答、连续追问、停止和重试，每条新闻保留本次运行中的会话。
- 事件中心中栏使用内置浏览器打开原文；应用内网站登录状态可供用户浏览和 AI 研究复用。
- 深度研究通过 Pi 运行时调用搜索、浏览器和已配置的 MCP 工具，并为阅读材料登记引用。
- 支持连接符合 `/v1/sources` 契约的自建数据服务。

## 使用多个小组件

在桌面右键组件，选择“编辑小组件”：

- **固定榜单**：把“显示榜单”设为知乎，保持“固定显示此榜单”开启。另一个组件设为微博，即可分别展示。
- **点击切换**：关闭“固定显示此榜单”，用标签或左右箭头浏览。为同尺寸的多个可切换组件选择不同的“组件编号”，例如“组件 1”和“组件 2”。

新组件默认固定显示所选榜单。已有组件可通过上述配置调整。不同尺寸的切换状态自动分开；同尺寸、同起始榜单、同编号的可切换组件共用选择记录。

## 开发

```sh
rtk swift test --scratch-path /Volumes/TrendingTabBuild/swift
rtk xcodebuild -project TrendingTab.xcodeproj -scheme TrendingTab -destination 'platform=macOS' -derivedDataPath /Volumes/TrendingTabBuild/DerivedData CODE_SIGNING_ALLOWED=NO build
rtk env SIGNING_MODE=ad-hoc zsh scripts/package-dmg.sh
```

外接 APFS 构建卷可用时优先使用上述缓存路径；未挂载时省略路径参数。打包脚本默认使用 `SIGNING_MODE=auto`：证书和两份 provisioning profile 都可用时选择 Developer ID，否则生成 ad-hoc 签名的 DMG。

`main` 分支的 CI 会运行测试、构建同时支持 Apple Silicon 与 Intel 的 DMG，把 DMG 和 SHA-256 作为 Actions Artifact 保存，并发布到 GitHub Release。完整签名和公证配置见 [发布与签名](docs/release.md)。

应用、Widget、随包 Node 和 Pi 原生插件均采用 arm64／x86_64 Universal 架构；Apple Silicon 默认使用原生 ARM。打包和 CI 会检查每个 Mach-O 文件，Intel 执行由 Intel runner 验证。macOS 28 的实际兼容性需在对应系统发布后另行验收。

## 文档

- [架构与数据模型](docs/architecture.md)
- [接入新平台](docs/adding-a-source.md)
- [AI 与提醒](docs/ai-and-alerts.md)
- [验证记录](docs/verification.md)
- [浏览器与 Pi 验收清单](docs/browser-agent-acceptance.md)

## 许可

项目采用 MIT 许可。第三方代码和请求格式参考见 [NOTICE.md](NOTICE.md)。
