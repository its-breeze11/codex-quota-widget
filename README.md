# Codex Quota Widget

一个只在本机运行的 macOS 菜单栏与桌面悬浮工具，用于查看 Codex 当前额度窗口、可用重置次数和每日 Token 历史。

## 能力

- 展示 Codex 主额度的剩余百分比和重置倒计时，不展示模型专属额度桶。
- 展示可用重置次数，以及每张重置券的到期时间。
- 展示 7 天、30 天和全部每日 Token 柱状图，Token 数统一使用 `M`。
- 将服务端返回的每日 Token 合并保存到本机 SQLite。
- 每 60 秒自动刷新今日 Token，并核验最近 7 个已结束日期；也可手动全量核验。
- 支持拖动窗口边缘调整大小；宽窗口为双栏，窄窗口自动切换为纵向滚动布局。
- 不读取、复制或保存 Codex 登录令牌，不提供消耗重置券的操作。

## 数据来源

应用启动本机 `codex app-server --stdio`，通过只读方法读取：

- `account/rateLimits/read`
- `account/usage/read`

额度接口返回窗口内已使用百分比，不返回可换算的 Token 总容量。因此应用只显示剩余比例，不用每日 Token 反推额度。

## 隐私与安全

- 应用不读取、复制、保存或上传 Codex 登录令牌，也不包含遥测、分析 SDK 或自建网络请求。
- 为补齐“今日”实时用量，应用会流式扫描 `~/.codex/sessions` 内的 `.jsonl` 会话记录，只解析 `token_count` 事件；提示词、响应正文和其他事件不会被保存或上传。
- 本地 SQLite 仅保存日期、聚合 Token 数和同步时间：`~/Library/Application Support/CodexQuotaWidget/usage.sqlite3`。
- 额度和历史数据由本机 Codex CLI 的只读 App Server 方法返回。请只在你信任本机 Codex 安装和本地用户目录权限的设备上运行。
- 公开仓库不包含真实账户截图、会话日志、数据库或构建产物。若提交 Issue、日志或截图，请先移除账户、额度、路径和会话内容。

## 环境要求

- macOS 13 或更高版本
- 如果尚未安装 Codex CLI，应用会征得确认后通过本机 npm 安装固定版本 `@openai/codex@0.146.0` 到 `~/.local`（无需管理员权限）。升级 CLI 版本需要更新并审阅本仓库源码。
- CLI 安装完成后，应用会征得确认并打开 `codex login`；账户网页登录只能由本人完成。应用不读取或保存登录凭据，登录成功后会自动启用刷新。
- 自动安装依赖本机已有 Node/npm；缺少时应用会打开 Node.js 官方下载页，安装完成后点击刷新即可继续。
- 匹配的 Swift 工具链和 macOS SDK；推荐完整 Xcode

## 构建

```bash
zsh scripts/package_app.sh
```

生成结果：

`dist/Codex Quota Widget.app`

首次打开如果被 macOS 拦截，可在“系统设置 → 隐私与安全性”中允许打开。本项目当前使用本机 ad-hoc 签名，仅适合本地开发；对外发布应使用 Developer ID 签名和 notarization。
