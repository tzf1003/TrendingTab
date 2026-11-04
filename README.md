# TrendingTab

TrendingTab 是一个 macOS 14+ 的热榜聚合应用。桌面小组件负责快速浏览，菜单栏负责刷新、暂停采集和打开设置，本地服务负责采集、聚合、AI 判断与提醒。

## 功能

- 平台榜单、聚合、重大事件、主题和事件追踪使用同一级标签，可排序、隐藏和独立订阅提醒。
- 默认每 15 分钟采集，可设置为 5 至 1440 分钟。
- 首版接入 17 个来源，每个来源使用独立适配器。
- 支持 OpenAI Responses、OpenAI Chat Completions 和 Anthropic Messages。
- 支持连接符合 `/v1/sources` 契约的自建数据服务。

## 开发

```sh
swift test --build-path /Volumes/TrendingTabBuild/swift --cache-path /Volumes/TrendingTabBuild/cache
xcodebuild -project TrendingTab.xcodeproj -scheme TrendingTab -destination 'platform=macOS' build
```

外接 APFS 构建卷可用时优先使用上述缓存路径；未挂载时省略两个路径参数。

## 文档

- [架构与数据模型](docs/architecture.md)
- [接入新平台](docs/adding-a-source.md)
- [AI 与提醒](docs/ai-and-alerts.md)
- [验证记录](docs/verification.md)

## 许可

项目采用 MIT 许可。第三方代码和请求格式参考见 [NOTICE.md](NOTICE.md)。
