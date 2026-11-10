# cguard 更新日志

本项目遵循 [语义化版本](https://semver.org/lang/zh-CN/)。
格式参考 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/)。

## [1.0.0] - 2026-11-10

首个可用版本。

### 新增

- `scan`：测量 23 个已知的「吃盘」位置，按 safe / apps / review 三档输出，只读不改。
- `clean`：默认 dry-run（只报数字不删）；`-Force` 才动手。
  - `-Only <ids>` 只处理指定目标
  - `-Tier <safe|apps>` 按档位处理
  - `-Admin` 自动请求一次 UAC，处理需要管理员的位置
  - `-Auto` 只在 C 盘低于阈值时才动手
  - `-ReportPath <file>` 输出 Markdown 报告
- `doctor`：解释「为什么满了」——顶层目录、用户目录 TOP 8、卷影副本、休眠文件、OEM 修复快照、缓存重定向现状。
- `relocate`：把 npm / pnpm / yarn / uv / pip / bun / Puppeteer / Playwright 缓存永久搬到其它盘，从源头止住增长。
- `watch`：注册计划任务，每 6 小时检查一次，只在空间不足时清理。命令长度自动控制在 schtasks 的 261 字符上限内。
- 23 个内置目标，覆盖：
  - OpenCode（`shell` / `tool-output` / `log` / `snapshot`，保留 `opencode.db`）
  - Codex 运行时缓存
  - WorkBuddy / CodeBuddy / Cursor / VS Code 缓存
  - Claude Desktop 渲染层缓存
  - Puppeteer / Playwright 浏览器二进制
  - npm / pnpm / yarn / bun / uv / pip / cargo 包缓存
  - Windows：Temp、Windows Update、传递优化、崩溃转储、缩略图、`$WinREAgent`
  - Dell SupportAssist 修复快照
- 安全模型：三档分级、`keep` 名单、`minAgeDays`、只读档永不删除、锁定文件跳过不强制。
- 审计日志：每次运行追加一行到 `%LOCALAPPDATA%\cguard\cguard.log`。
- `install.ps1`：一行命令安装（`irm ... | iex`），无需 git、无需管理员。
  自动写 `cguard.cmd` 启动器、加用户 PATH、可选装计划任务，支持 `-Uninstall`。
  从零下载安装实测 7.4 秒。
  - 卸载支持「站在安装目录里执行」：脚本自身占用目录时改为退出后延迟删除，8 秒内清干净。
  - 二次安装不加 `-Force` 会拒绝覆盖并提示，不会静默破坏现有安装。
- 自测 32 项断言 + 安装器 16 项断言，全部在临时沙箱里跑，不碰真实缓存。
- GitHub Actions：PowerShell 5.1 + 7 双版本跑两套测试、语法检查、侧效应检查。
- `README.zh-CN.md`：完整中文文档，含与「电脑管家类」软件的能力对照表（明确说明
  cguard 不杀毒、不拦弹窗、不装驱动、不卸载软件）。

### 已知限制

- Docker / WSL 的 `ext4.vhdx` 只报告不处理，需要 `wsl --manage <distro> --set-sparse true`。
- 需要管理员的位置在非提权会话下会被标记为 `skipped-needs-admin`，不会静默跳过而不告知。
- 卷影副本与 OEM 快照的清理走官方命令，不直接删文件。
