# 版本规范

## 版本格式

```
{MAJOR.MINOR.PATCH}-{YYYYMMDD}-{developer}
```

示例：`2.0.2-20260811-rex`

### 各段含义

| 段 | 说明 | 维护方式 |
|---|---|---|
| `MAJOR.MINOR.PATCH` | 语义化版本号 | 手动维护，在 `Info.plist` 的 `CFBundleShortVersionString` 中修改 |
| `YYYYMMDD` | 构建日期 | 构建脚本自动生成 |
| `developer` | 开发者标识 | 构建脚本自动解析，见下方规则 |

### 开发者标识解析优先级

1. 环境变量 `DEVELOPER`（最高优先级）
2. 项目根目录 `.developer` 文件（一行文本，已加入 `.gitignore`，每个开发者本地创建）
3. `git config user.name`（自动清理为小写字母数字+连字符）
4. `unknown`（兜底）

## 开发者首次配置

在项目根目录创建 `.developer` 文件，写入自己的短名：

```bash
echo "yourname" > .developer
```

该文件已被 `.gitignore` 忽略，不会提交到仓库。

## 发版流程

1. 修改 `Info.plist` 中 `CFBundleShortVersionString` 的版本号（遵循语义化版本）
2. 运行 `zsh scripts/package_app.sh` 构建
3. 构建脚本自动拼接日期和开发者标识，注入 `FullVersionString`
4. App 内左下角显示完整版本号

## 技术细节

- 构建脚本：`scripts/package_app.sh`
- 完整版本号通过 `PlistBuddy` 写入打包后的 `Info.plist` 的 `FullVersionString` 键
- `CFBundleVersion`（build 号）仍为 git commit 总数，用于系统区分构建
- `GitCommitHash` 仍注入，用于排障
