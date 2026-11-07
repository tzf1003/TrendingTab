# 发布、Developer ID 与公证

CI 固定产出 `TrendingTab-<版本>.dmg`，并验收独立的 `TrendingTab-AgentRuntime-<版本>.dmg`。正式发布要求 Developer ID 签名及 Apple 公证；测试分支可生成 ad-hoc 制品。DMG 与 `.sha256` 同时保存到 Actions Artifact，主分支在 Intel 验证通过后发布 Latest Release。

## 1. Apple Developer 准备

在 Apple Developer 后台确认以下 App ID 和 App Group：

- `dev.trendingtab.app`
- `dev.trendingtab.app.widget`
- `group.dev.trendingtab.shared`

为两个 App ID 启用 App Groups，并把 `group.dev.trendingtab.shared` 分配给它们。然后使用团队中的 Developer ID Application 证书，分别为两个 App ID 创建 **Developer ID Application** provisioning profile。

主应用和 Widget 的 profile 必须分别包含对应 App ID。Widget profile 还必须包含 App Group，否则签名后的桌面组件无法读取主应用快照。

## 2. GitHub Actions Secrets

在公开仓库中不要把证书或 profile 写成文件提交。将 `.p12` 和 `.mobileprovision` 文件的 Base64 内容写入 Actions Secrets：

```sh
rtk /usr/bin/base64 -i DeveloperID.p12 | rtk gh secret set APPLE_CERTIFICATE_P12 --repo tzf1003/TrendingTab
rtk /usr/bin/base64 -i TrendingTab.mobileprovision | rtk gh secret set APPLE_APP_PROVISIONING_PROFILE --repo tzf1003/TrendingTab
rtk /usr/bin/base64 -i TrendingTabWidget.mobileprovision | rtk gh secret set APPLE_WIDGET_PROVISIONING_PROFILE --repo tzf1003/TrendingTab
```

再设置：

- `APPLE_CERTIFICATE_PASSWORD`：导出 `.p12` 时设置的密码。
- `KEYCHAIN_PASSWORD`：可选；不设置时 CI 每次生成临时随机密码。
- `NOTARY_APPLE_ID`：用于公证的 Apple ID。
- `NOTARY_APPLE_PASSWORD`：Apple ID 的 app-specific password。
- `NOTARY_TEAM_ID`：Developer Team ID。

证书、主应用 profile 和 Widget profile 三项必须同时存在。正式发布还会核对公证配置；缺少任一必需配置时，发布检查失败。

## 3. 构建与验证

推送 `main` 或手动运行工作流：

```sh
rtk gh workflow run ci.yml --repo tzf1003/TrendingTab --ref main
```

工作流会完成以下验收：

1. Swift 测试。
2. 生成 arm64 + x86_64 应用与 Widget。
3. 校验主应用和 Widget 的 App Group entitlement。
4. 校验 Widget sandbox、扩展点和嵌套代码签名。
5. 对 Developer ID 构建提交 Apple 公证并 stapling。
6. 校验 DMG、生成 SHA-256、上传 Artifact 并发布 Latest Release。

Developer ID 构建默认请求 Apple 安全时间戳，并在签名时进行有限重试。`CODESIGN_TIMESTAMP=none` 只用于本地 ad-hoc 测试；需要公证的构建会拒绝使用该设置。

最终签名保留 Xcode 生成的 Team ID、App ID 和 App Group，移除调试用的 `com.apple.security.get-task-allow`。打包校验同时检查这些运行身份和分发权限。公证状态必须为 `Accepted` 才会装订票据；Apple 拒绝时，CI 会输出对应的诊断日志。已有提交也可通过 `Notarization diagnostics` 工作流按 submission ID 查询。

应用内“设置 → 软件更新”读取 GitHub Latest Release。下载后会核对版本、可用的 GitHub 资产 SHA-256、bundle identifier 和代码签名，再通过临时目录和备份完成原子替换。API 限流时显示对应原因及发布页入口。

Agent Runtime 使用独立版本，版本来源为 `AgentRuntime/package.json`；发布前须同步更新 `package-lock.json` 的根包版本。主应用 CI 以该版本构建并验收独立组件，同一版本已有公开组件时不会重复上传。单独执行 `Agent Runtime release` 工作流时，输入版本须与这两个文件一致。每次更改随包运行时代码或依赖并准备发布组件时，应提升该版本，确保组件版本准确标识对应内容。

独立组件工作流在 Apple Silicon 和 Intel 上分别验证签名、公证与健康检查后，发布 `runtime-v<版本>`，并保持主应用的 Latest Release。运行时随包保留 Pi 的 MIT 许可、`NODE-LICENSE` 和依赖包的许可文件；CI 比较应用与独立组件内的 Pi 许可全文。

## 4. 本地打包

本机只做安装验收时可显式使用 ad-hoc：

```sh
rtk env SIGNING_MODE=ad-hoc \
DERIVED_DATA_PATH=/Volumes/TrendingTabBuild/DerivedData \
OUTPUT_DIR=/Volumes/TrendingTabBuild/release \
zsh scripts/package-dmg.sh
```

本机已导入两份 profile 时，可把 profile UUID 传给脚本：

```sh
rtk env SIGNING_MODE=developer-id \
TRENDINGTAB_APP_PROFILE_ID=<主应用 profile UUID> \
TRENDINGTAB_WIDGET_PROFILE_ID=<Widget profile UUID> \
DEVELOPMENT_TEAM=<Team ID> \
zsh scripts/package-dmg.sh
```
