# TrendingTab

TrendingTab 是一个 macOS 14+ 的热榜聚合应用。桌面小组件负责快速浏览，菜单栏负责刷新、暂停采集和打开设置，本地服务负责采集、聚合、AI 判断与提醒。

## 功能

- 事件中心按榜单热度排序，标签可直接点击并用两端箭头切换；列表只显示本次榜单和更新时间。
- 平台榜单、聚合、重大事件、主题和事件追踪使用同一级标签，可排序、隐藏和独立订阅提醒。
- 默认每 15 分钟采集，可设置为 5 至 1440 分钟。
- 首版接入 17 个来源，每个来源使用独立适配器。
- 小、中、大三种 Widget 复用完整卡片空间；中、大尺寸使用双列，并从标题起始展示每一条内容。
- 设置页自动读取 GitHub 最新 Release，发现新版本后可下载并一键安装。
- 支持 OpenAI Responses、OpenAI Chat Completions 和 Anthropic Messages。
- 支持连接符合 `/v1/sources` 契约的自建数据服务。

## 开发

```sh
swift test --build-path /Volumes/TrendingTabBuild/swift --cache-path /Volumes/TrendingTabBuild/cache
xcodebuild -project TrendingTab.xcodeproj -scheme TrendingTab -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO build
SIGNING_MODE=ad-hoc zsh scripts/package-dmg.sh
```

外接 APFS 构建卷可用时优先使用上述缓存路径；未挂载时省略两个路径参数。打包脚本默认使用 `SIGNING_MODE=auto`：证书和两份 provisioning profile 都可用时才选择 Developer ID，否则生成 ad-hoc 签名的 DMG。

`main` 分支的 CI 会运行测试、构建同时支持 Apple Silicon 与 Intel 的 DMG，把 DMG 和 SHA-256 作为 Actions Artifact 保存，并发布到 GitHub Release。完整签名和公证配置见 [发布与签名](docs/release.md)。

## 文档

- [架构与数据模型](docs/architecture.md)
- [接入新平台](docs/adding-a-source.md)
- [AI 与提醒](docs/ai-and-alerts.md)
- [验证记录](docs/verification.md)

## 许可

项目采用 MIT 许可。第三方代码和请求格式参考见 [NOTICE.md](NOTICE.md)。
