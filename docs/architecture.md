# 架构

TrendingTab 使用一个 Xcode 工程和本地 Swift Package。

| 模块 | 职责 |
|---|---|
| `TrendingTabCore` | 来源、条目、标签、事件、快照和设置模型 |
| `TrendingTabNetworking` | HTTP、并发限制、条件缓存和状态码映射 |
| `TrendingTabSources` | 每个平台的独立请求与解析 |
| `TrendingTabPersistence` | SQLite、迁移、历史、AI 运行和提醒记录 |
| `TrendingTabAggregation` | 标签筛选、排序、事件归并和快照计算 |
| `TrendingTabIntelligence` | 三种模型协议、流式输出和引用校验 |
| `TrendingTabNotifications` | 免打扰、频率和跨标签合并 |
| `TrendingTabWidgetBridge` | 原子快照与跨进程标签选择 |
| `TrendingTabKit` | 主应用协调采集、分析和发布 |

主应用写入 SQLite。Widget Extension 读取 App Group 中同一代快照，快照同时包含配置、标签内容和来源状态。标签切换只修改选择文件并请求 WidgetKit 重载。

条目身份优先使用平台原生 ID，否则使用去除跟踪参数后的 URL 哈希。平台标签保留原排名；跨平台标签使用排名融合和时效，不直接相加热度原值。
