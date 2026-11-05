# 发布、Developer ID 与公证

CI 固定产出 `TrendingTab-<版本>.dmg`。即使没有 Apple 签名资料，工作流仍会生成可挂载的 ad-hoc DMG，并将 DMG 与 `.sha256` 上传为 Actions Artifact；配置完整 Developer ID 资料后，同一工作流会改为签名并提交公证。

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
/usr/bin/base64 -i DeveloperID.p12 | gh secret set APPLE_CERTIFICATE_P12 --repo tzf1003/TrendingTab
/usr/bin/base64 -i TrendingTab.mobileprovision | gh secret set APPLE_APP_PROVISIONING_PROFILE --repo tzf1003/TrendingTab
/usr/bin/base64 -i TrendingTabWidget.mobileprovision | gh secret set APPLE_WIDGET_PROVISIONING_PROFILE --repo tzf1003/TrendingTab
```

再设置：

- `APPLE_CERTIFICATE_PASSWORD`：导出 `.p12` 时设置的密码。
- `KEYCHAIN_PASSWORD`：可选；不设置时 CI 每次生成临时随机密码。
- `NOTARY_APPLE_ID`：用于公证的 Apple ID。
- `NOTARY_APPLE_PASSWORD`：Apple ID 的 app-specific password。
- `NOTARY_TEAM_ID`：Developer Team ID。

证书、主应用 profile 和 Widget profile 三项必须同时存在。资料完整时 CI 使用 Developer ID；否则生成 ad-hoc DMG 并在日志中写明签名模式。

## 3. 构建与验证

推送 `main` 或手动运行工作流：

```sh
gh workflow run ci.yml --repo tzf1003/TrendingTab --ref main
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

应用内“设置 → 更新”读取 GitHub Latest Release。下载后会核对版本、SHA-256、bundle identifier 和代码签名，再通过临时目录和备份完成原子替换。

## 4. 本地打包

本机只做安装验收时可显式使用 ad-hoc：

```sh
SIGNING_MODE=ad-hoc \
DERIVED_DATA_PATH=/Volumes/TrendingTabBuild/DerivedData \
OUTPUT_DIR=/Volumes/TrendingTabBuild/release \
zsh scripts/package-dmg.sh
```

本机已导入两份 profile 时，可把 profile UUID 传给脚本：

```sh
SIGNING_MODE=developer-id \
TRENDINGTAB_APP_PROFILE_ID=<主应用 profile UUID> \
TRENDINGTAB_WIDGET_PROFILE_ID=<Widget profile UUID> \
DEVELOPMENT_TEAM=<Team ID> \
zsh scripts/package-dmg.sh
```
