# Codex Quota Widget

一个只在本机运行的 macOS 菜单栏与桌面悬浮工具，用于查看 Codex 当前额度窗口、可用重置次数和每日 Token 历史。

## 界面

| 收起态 | 展开态 |
| --- | --- |
| ![收起态：额度与重置次数](assets/dashboard-collapsed.png) | ![展开态：额度、重置、消耗趋势与核验](assets/dashboard-expanded.png) |

### 展开态：30 天范围

![展开态：30 天 Token 消耗趋势](assets/dashboard-expanded-30d.png)

### 展开态：全部范围

![展开态：全部 Token 消耗趋势](assets/dashboard-expanded-all.png)

### 消耗计算详情

![7d 与 30d 消耗的逐日计算明细](assets/usage-calculation-details.png)

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

## 环境要求

- macOS 13 或更高版本
- 如果尚未安装 Codex CLI，应用会征得确认后通过本机 npm 安装到 `~/.local`（无需管理员权限）
- CLI 安装完成后，应用会征得确认并打开 `codex login`；账户网页登录只能由本人完成。应用不读取或保存登录凭据，登录成功后会自动启用刷新。
- 自动安装依赖本机已有 Node/npm；缺少时应用会打开 Node.js 官方下载页，安装完成后点击刷新即可继续。
- 匹配的 Swift 工具链和 macOS SDK；推荐完整 Xcode

## 构建

```bash
zsh scripts/package_app.sh
```

生成结果：

`dist/Codex Quota Widget.app`

首次打开如果被 macOS 拦截，可在“系统设置 → 隐私与安全性”中允许打开。本项目当前使用本机 ad-hoc 签名，不适合直接对外分发。

## 本地数据

每日 Token 历史保存在：

`~/Library/Application Support/CodexQuotaWidget/usage.sqlite3`

官方没有承诺历史数据保留时长。应用只能保存首次运行时服务端仍能返回的数据，以及后续同步到本机的数据。
