# 验证记录

## 2026-11-05

- `swift test`：11 项通过，覆盖发布版本解析、独立 Widget 选择、精确条目跳转、数据库清理、17 源目录和核心聚合规则。
- Release 构建：主应用和 Widget 均为 arm64 + x86_64 通用二进制。
- 签名：主应用和 Widget 都包含 `group.dev.trendingtab.shared`；Widget 另含 sandbox 与网络客户端权限。
- 运行时：`dev.trendingtab.app.widget` 已注册并启动，Widget 进程成功读取主应用写入 Group Container 的同一份快照。
- DMG：`hdiutil verify` 通过，挂载后应用、嵌套 Widget 和扩展点校验通过。
- 界面：实际打开事件中心与设置，检查热度排序、点击切标签、底部翻页、更新时间元数据和卡片布局。

## 2026-11-04

- `swift test`：8 项通过，覆盖身份、排序、证据门槛、免打扰、引用校验、RSS、百度样本、数据库迁移和 17 源目录。
- 2026-11-04 真实读取：16/17 个来源返回有效条目。微信热文保持“需要配置 RSS 或自建服务”，未配置不计为可用来源。
- 8 小时连续运行、真实模型准确率和签名公证需要在对应环境中单独执行。

## DMG

`zsh scripts/package-dmg.sh` 生成 `build/release/TrendingTab-<版本>.dmg`。验收时检查 DMG 可挂载、应用签名校验通过，并且应用可以启动。CI 在 `main` 上把同一产物发布为 GitHub Release。
