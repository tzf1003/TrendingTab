# AI 与提醒

三个协议分别实现请求、认证、流式事件和用量解析：

| 协议 | 相对路径 |
|---|---|
| OpenAI Responses | `responses` |
| OpenAI Chat Completions | `chat/completions` |
| Anthropic Messages | `messages` |

API 根地址按相对路径拼接。凭据保存在 Keychain，配置导出不包含密钥。OpenAI 请求在支持时设置 `store: false`。

自动分析默认每天 100 次、100,000 tokens。请求先持久化预留；结果未知时保守记账且不自动重发。模型输出必须是 JSON，未知证据 ID 会被拒绝。

重大事件默认要求重要度不低于 75、置信度不低于 0.8，并具备两个独立来源或用户指定的权威来源。提醒默认关闭，开启后使用 23:00–08:00 免打扰、每小时 3 次、每天 10 次和 6 小时事件冷却。
