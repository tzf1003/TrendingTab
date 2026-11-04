# 接入新平台

1. 在 `Sources/TrendingTabSources/Builtins/` 添加独立 Provider 文件。
2. 声明来源分类、榜单、主页、最低刷新间隔和解析器版本。
3. 在 `SourceCatalog.providers` 注册。
4. 将响应样本放入 `Tests/TrendingTabKitTests/Fixtures`，覆盖正常、空榜、缺字段、401、403、429 和结构变化。
5. 增加解析测试，不修改调度器、AI 或界面。

RSS 来源可以直接通过 `FeedSource` 配置。微信热文需要用户提供公众号 RSS 或符合远程契约的数据服务。

远程契约：

```text
GET /v1/sources
GET /v1/sources/{sourceID}/boards/{boardID}/items
```

响应包含 `schemaVersion`、来源、榜单、采集时间和标准条目。每个来源明确选择本地或远端模式。
