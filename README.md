# Codex ImageGen Relay Fix

在 macOS 和 Windows 上修复 Codex Desktop 自定义 OpenAI 兼容 provider 的内置 `image_gen` 调用，让支持工具调用的对话模型通过中转使用 `gpt-image-2` 生成图片。

脚本不会切换到 OpenAI 官方 provider，不修改 Codex 二进制，也不使用 Node、Python 或 MCP 图片 wrapper 提供鉴权。

## 解决的问题

部分自定义 provider 可以正常调用 `/v1/responses`，但 Codex 内置 `image_gen` 不可见或无法完成鉴权。常见原因包括：

- provider 仍使用 `requires_openai_auth = true`；
- API Key 被静态写在 `config.toml`；
- `auth = { command = ... }` 与 `env_key` 冲突；
- Codex Desktop 进程没有继承 `OPENAI_API_KEY`；
- `[features]` 缺少 `image_generation = true`；
- 中转地址缺少 `/v1`。

## 脚本会做什么

macOS 的 `fix-codex-imagegen-macos.sh` 和 Windows 的 `fix-codex-imagegen-windows.ps1` 会：

1. 从 `$CODEX_HOME/auth.json` 或 `~/.codex/auth.json` 在内存中读取 `OPENAI_API_KEY`。
2. 修正当前启用的自定义 provider，同时保留 `config.toml` 的其他 section。
3. 删除该 provider 内旧的 `auth`、`experimental_bearer_token` 和 Node helper 引用。
4. 合并 `[features]`，启用 `image_generation = true`，不会创建重复 section。
5. macOS 安装用户级 LaunchAgent；Windows 写入当前用户环境变量，保证新启动的桌面进程可以继承。
6. 验证 `/v1/models` 和 `/v1/responses`；macOS 额外检查 Codex 原生二进制。
7. 确认中转同时提供 `gpt-image-2` 和 `gpt-5.4`。

脚本可以重复运行，重复执行不会继续改变已经正确的配置。

## 前置条件

- macOS 或 Windows；
- macOS：Codex Desktop 安装在 `/Applications/Codex.app`；Windows：已安装 Codex Desktop，并能在新进程中启动；
- macOS：`~/.codex/config.toml` 和 `~/.codex/auth.json`；Windows：`%CODEX_HOME%\config.toml` 和 `%CODEX_HOME%\auth.json`，未设置时使用 `%USERPROFILE%\.codex`；
- 对应 `auth.json` 中存在非空 `OPENAI_API_KEY`；
- 中转实现兼容的 `/v1/models` 和 `/v1/responses`；
- macOS 系统可以使用 `curl`、`awk`、`plutil` 和 `launchctl`；Windows 使用 PowerShell 内置 HTTP 客户端。

不要把完整 API Key 粘贴到聊天、README、脚本或 `config.toml`。

## 一键安装

### macOS

```bash
git clone https://github.com/xianyu110/codex-imagegen-relay-fix.git
cd codex-imagegen-relay-fix
chmod 700 fix-codex-imagegen-macos.sh
./fix-codex-imagegen-macos.sh
```

默认中转地址：

```text
https://codex.maynor1024.live/v1
```

使用其他兼容中转时，通过环境变量覆盖，不需要修改脚本：

```bash
CODEX_RELAY_BASE_URL='https://relay.example.com/v1' ./fix-codex-imagegen-macos.sh
```

### Windows PowerShell

在 PowerShell 中运行（不要在 CMD 中直接执行 `.ps1`）：

```powershell
git clone https://github.com/xianyu110/codex-imagegen-relay-fix.git
Set-Location codex-imagegen-relay-fix
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
.\fix-codex-imagegen-windows.ps1
```

使用其他兼容中转时，可以通过参数或当前 PowerShell 会话变量覆盖地址：

```powershell
.\fix-codex-imagegen-windows.ps1 -RelayBaseUrl 'https://relay.example.com/v1'
# 或：$env:CODEX_RELAY_BASE_URL = 'https://relay.example.com/v1'
```

Windows 脚本从 `%CODEX_HOME%\auth.json` 或 `%USERPROFILE%\.codex\auth.json` 读取已有 `OPENAI_API_KEY`，并写入当前用户作用域的环境变量。它不会把 Key 写入 `config.toml`、脚本或日志；环境变量只会被之后启动的进程读取。

如果 PowerShell 因执行策略拒绝脚本，`Set-ExecutionPolicy -Scope Process` 只影响当前窗口，不会修改系统策略。企业设备仍可能由组策略禁止执行，此时应让管理员审核脚本，而不是关闭全部安全策略。

## 生成的 provider 配置

脚本会修改当前 `model_provider` 对应的 section，结果等价于：

```toml
[model_providers.custom]
name = "custom"
base_url = "https://relay.example.com/v1"
wire_api = "responses"
requires_openai_auth = false
env_key = "OPENAI_API_KEY"
http_headers = { "x-openai-actor-authorization" = "local-relay" }

[features]
image_generation = true
```

`x-openai-actor-authorization` 只是 Codex 内部门控需要的固定占位值，不是凭据。中转服务应忽略或剥离这个 Header。

不要把 Codex 对话主模型设置成 `gpt-image-2`。新任务使用 `gpt-5.4` 等支持工具调用的模型；内置 `image_gen` 会负责图片生成。

## 成功输出

macOS 正常执行会看到类似输出：

```text
OPENAI_API_KEY(auth.json)=EXISTS
OPENAI_API_KEY(macOS user launchd)=EXISTS
provider_config=OK
codex_version=codex-cli 0.145.0-alpha.30
models_http=200
gpt-image-2=AVAILABLE
gpt-5.4=AVAILABLE
responses_http=200
image_generation_config=READY
```

脚本只报告 Key 存在或不存在，不会输出 Key。

## 完成后必须重启

已经运行的 Codex Desktop 后台进程不会自动继承新环境变量，macOS 和 Windows 都必须重新启动应用。

1. 完全退出 Codex Desktop，包括后台进程。
2. 重新启动 Codex。
3. 新建任务，不要沿用修复前的会话。
4. 使用 `gpt-5.4` 等工具调用模型。
5. 在任务中要求调用内置 `image_gen`。

## 安全模型

- Key 只从现有 `auth.json` 读取到进程内存。
- Key 不会写入仓库、脚本、LaunchAgent plist、`config.toml` 或日志；Windows 会按设计写入当前用户环境变量，以便新启动的桌面进程继承。
- provider 只使用 `env_key = "OPENAI_API_KEY"`。
- 登录 helper 只负责向当前用户的 launchd 会话注入环境变量，不参与每次 provider 请求。
- LaunchAgent 的标准输出和错误输出均指向 `/dev/null`。
- `auth.json`、`config.toml`、`.env` 和日志已加入 `.gitignore`。

同一 macOS 用户下运行的进程可能读取该用户会话的环境信息，因此仍应保护本机账户和 `~/.codex/auth.json` 的文件权限。

## 安装的本地文件

```text
~/.codex/bin/codex-imagegen-env.sh
~/Library/LaunchAgents/com.maynor.codex-imagegen-env.plist
```

Windows 不安装常驻服务，只使用当前用户的 `OPENAI_API_KEY` 环境变量。检查是否已经写入（只显示是否存在）：

```powershell
if ([string]::IsNullOrWhiteSpace([Environment]::GetEnvironmentVariable('OPENAI_API_KEY', 'User'))) { 'MISSING' } else { 'EXISTS' }
```

## 卸载登录环境注入

以下命令只删除本工具安装的两个文件并清除当前用户会话变量，不会删除 `auth.json`：

```bash
uid="$(id -u)"
launchctl bootout "gui/$uid/com.maynor.codex-imagegen-env" 2>/dev/null || true
launchctl unsetenv OPENAI_API_KEY
unlink "$HOME/Library/LaunchAgents/com.maynor.codex-imagegen-env.plist"
unlink "${CODEX_HOME:-$HOME/.codex}/bin/codex-imagegen-env.sh"
```

卸载后需自行检查 `~/.codex/config.toml` 是否需要恢复为其他 provider 配置。

Windows 若要移除本工具写入的用户级环境变量（不会删除 `auth.json`）：

```powershell
[Environment]::SetEnvironmentVariable('OPENAI_API_KEY', $null, 'User')
Remove-Item Env:OPENAI_API_KEY -ErrorAction SilentlyContinue
```

## 故障排查

### `OPENAI_API_KEY(auth.json)=MISSING`

确认 `$CODEX_HOME/auth.json` 或 `~/.codex/auth.json` 中存在非空 `OPENAI_API_KEY`。Windows 对应路径是 `%CODEX_HOME%\auth.json` 或 `%USERPROFILE%\.codex\auth.json`。不要把 Key 作为命令参数或粘贴到 Issue。

### `Missing native Codex binary`

脚本只支持官方 macOS Codex Desktop 的默认安装路径：

```text
/Applications/Codex.app/Contents/Resources/codex
```

### `gpt-image-2=UNAVAILABLE`

检查中转 `/v1/models` 是否列出 `gpt-image-2`，并确认当前 API Key 有权访问该模型。

### `responses_http` 不是 `2xx`

检查中转地址是否包含 `/v1`、是否支持 Responses API，以及 `gpt-5.4` 是否可用。

### 修复后仍看不到 `image_gen`

确认已经完全退出并重启 Codex，且使用的是新任务和支持工具调用的对话模型。Windows 若刚执行脚本后仍失败，请先关闭所有 Codex 窗口和后台进程，再从开始菜单重新启动；旧进程不会刷新用户环境变量。

## 已验证环境

- macOS 26.3；
- Codex Desktop 内置 CLI `0.145.0-alpha.30`；
- 自定义 Responses provider；
- `gpt-5.4` 对话模型；
- 内置 `image_gen` 调用 `gpt-image-2` 并产生本地 PNG。

Codex 后续版本可能调整内置图片工具门控。脚本不会修改二进制；如果配置字段发生变化，应先检查当前版本行为再更新脚本。
