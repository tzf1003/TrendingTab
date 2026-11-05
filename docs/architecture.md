# 架构

TrendingTab 使用一个 Xcode 工程和本地 Swift Package。

| 模块 | 职责 |
|---|---|
| `TrendingTabCore` | 来源、条目、标签、事件、快照和设置模型 |
| `TrendingTabNetworking` | HTTP、并发限制、条件缓存和状态码映射 |
| `TrendingTabSources` | 每个平台的独立请求与解析 |
| `TrendingTabPersistence` | SQLite、迁移、当前榜单缓存、AI 运行和提醒记录 |
| `TrendingTabAggregation` | 标签筛选、排序、事件归并和快照计算 |
| `TrendingTabIntelligence` | 三种模型协议、流式输出和引用校验 |
| `TrendingTabNotifications` | 免打扰、频率和跨标签合并 |
| `TrendingTabWidgetBridge` | 原子快照与跨进程标签选择 |
| `TrendingTabKit` | 主应用协调采集、分析和发布 |

主应用写入 SQLite，并把配置、标签内容和来源状态生成到 App Group 中的同一代快照。主应用与 Widget 都声明 `group.dev.trendingtab.shared`；Widget Extension 额外启用 sandbox 与网络客户端权限。每个 Widget 使用自己的配置与选择键，因此固定知乎和固定微博的组件不会联动。标签切换只修改对应组件的选择文件并请求 WidgetKit 重载。

可切换组件的选择键由默认榜单和「独立配置」槽构成，提供 8 个槽。相同配置共享选择，需要独立浏览时选择不同槽。删除或隐藏当前榜单后，依次回退到组件默认榜单、配置默认榜单及首个可用榜单。

榜单采集成功后，用当前结果替换该榜单，掉榜条目及其观察记录随即清理。每条快照内容带独立到期时间，默认采集周期下为 30 分钟；长采集周期使用两倍周期。时间线包含到期后的状态，应用运行时每 30 秒清理过期内容。到期按条目处理，聚合榜中的有效来源继续展示。

主应用和扩展共同编译 `Shared/WidgetIntents.swift`。扩展只链接 Core 与 WidgetBridge，新闻 URL 携带条目、事件及标签身份，由主应用路由到事件中心。发布快照后，主应用请求对应 Widget 时间线刷新。

条目身份优先使用平台原生 ID，否则使用去除跟踪参数后的 URL 哈希。平台标签保留原排名；跨平台标签使用排名融合和时效，不直接相加热度原值。
