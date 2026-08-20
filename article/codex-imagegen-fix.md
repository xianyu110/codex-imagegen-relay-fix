# 我们团队修复了 Codex 升级到 GPT 后，客户端无法生图的问题

## 先运行脚本

如果你遇到“Codex 能聊天，但不能生图”，先按自己的系统执行对应脚本。两份脚本都只读取本机已有的 `auth.json`，不会把完整 Key 打印出来。

```bash
git clone https://github.com/xianyu110/codex-imagegen-relay-fix.git
cd codex-imagegen-relay-fix
chmod 700 fix-codex-imagegen-macos.sh
./fix-codex-imagegen-macos.sh
```

Windows PowerShell：

```powershell
git clone https://github.com/xianyu110/codex-imagegen-relay-fix.git
Set-Location codex-imagegen-relay-fix
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
.\fix-codex-imagegen-windows.ps1
```

Windows 使用 `%CODEX_HOME%\auth.json` 或 `%USERPROFILE%\.codex\auth.json`，并把 Key 写入当前用户作用域的 `OPENAI_API_KEY`。如果中转地址不同：

```powershell
.\fix-codex-imagegen-windows.ps1 -RelayBaseUrl 'https://relay.example.com/v1'
```

执行策略只对当前 PowerShell 窗口临时放行；不要为了运行脚本而关闭整机安全策略。

脚本会读取本机已有的 `~/.codex/auth.json`，只检查 `OPENAI_API_KEY` 是否存在，不会把 Key 打印出来，也不会写入配置文件。中转地址不是默认地址时，在运行前设置：

```bash
CODEX_RELAY_BASE_URL='https://momoai.asia/v1' ./fix-codex-imagegen-macos.sh
```

脚本显示验证通过后，完全退出 Codex（包括后台进程），再重新启动并新建任务。对话主模型使用支持工具调用的模型，例如 `gpt-5.4`；不要把主模型改成 `gpt-image-2`，图片会由内置 `image_gen` 工具自动调用。

如果脚本提示 `OPENAI_API_KEY(auth.json)=MISSING`，不要把 Key 粘贴到聊天或命令行参数中，应先在本机完成 Codex 登录或修复 `auth.json`，再重试。Windows 脚本会验证用户环境变量和新请求；本文记录的真实图片产物仍来自 macOS，Windows 需要在自己的机器上完成最后一次生成验证。



![Codex 图片生成修复封面](https://upload.maynor1024.live/file/1784724094048_codex-imagegen-fix-cover.png)

## 先说结论

这次故障表面上是“升级到 GPT 后不能生图”，本质上不是 GPT 模型没有图片能力，而是三段链路没有对齐：对话模型、Responses API 中转、Codex 内置 `image_gen`。

我们团队没有修改 Codex 二进制，也没有切换回 OpenAI 官方 provider。最终方案是在现有自定义 provider 上做最小配置修复，让环境变量负责 Bearer 鉴权，让固定的 actor header 满足内置工具的可见性门控，再通过用户级启动项确保桌面应用能继承环境变量。

这套方案已经在当前 macOS 设备上实测通过。文章不会把 macOS 实测结果包装成 Windows 已验证结论；Windows 用户需要按同样的链路检查环境变量和桌面进程继承关系。

## 故障现场：聊天能用，图片不行

最开始的现象很容易误导人：Codex 可以正常对话、写代码，甚至直接请求 `/v1/responses` 也能返回结果，但要求它画图时，`image_gen` 不可见、调用失败，或者没有本地 PNG 产物。

我们先排除了“模型不存在”这个猜测。中转的 `/v1/models` 返回 HTTP 200，模型列表同时包含 `gpt-5.4` 和 `gpt-image-2`。接着用 `gpt-5.4` 请求 `/v1/responses`，同样返回 HTTP 200。

因此，问题不是中转完全不可用，也不是把图片模型误当成了聊天主模型。正确关系应该是：

```text
Codex 对话模型（例如 gpt-5.4）
        |
        +--> 内置 image_gen 工具
                    |
                    +--> 中转调用 gpt-image-2
                    |
                    +--> 本地 PNG 文件
```

![Codex 内置 image_gen 调用链路](https://upload.maynor1024.live/file/1784724119752_codex-imagegen-pipeline.png)

## 真正卡住我们的三个点

### 1. 官方鉴权门控和自定义 provider 冲突

当前版本的内置图片工具仍会检查 provider 是否要求官方鉴权。自定义中转如果保留了 `requires_openai_auth = true`，就可能让工具被隐藏或拒绝调用。本次实测的 `image_generation` 已是 stable/default 开启状态，因此不需要修改二进制或增加额外插件。

我们确认当前版本可复用的组合是：

```toml
requires_openai_auth = false
http_headers = { "x-openai-actor-authorization" = "local-relay" }
```

这里的 `local-relay` 只是非空静态占位值，不是凭据。中转服务应忽略或剥离这个 header，不能把它当成真实授权信息。

### 2. API Key 应由环境变量提供

provider 使用 `env_key = "OPENAI_API_KEY"`，Codex 才会在请求时以 Bearer 方式读取密钥。我们删除了同一 provider 下旧的 `auth = { command = ... }` 和 Node helper 引用，避免两套鉴权来源互相覆盖。

密钥只从本机已有的 `auth.json` 或安全输入流程注入用户环境，不写进 `config.toml`、脚本、日志或仓库。排查时也只输出存在/不存在状态。

### 3. 终端变量不等于桌面应用变量

这一步最容易被忽略。终端里的 `export OPENAI_API_KEY=...` 只影响当前 shell；从 Finder、Launchpad 或后台启动的 Codex Desktop 进程，可能根本看不到这个变量。

我们的 macOS 一键脚本安装了用户级 LaunchAgent，在登录时从 `auth.json` 读取密钥并用 `launchctl setenv` 注入。Windows 脚本使用 `[Environment]::SetEnvironmentVariable(..., 'User')` 写入当前用户环境。两者都只负责让新启动的 Codex 子进程继承环境，已经运行的进程必须重启。

## 最小配置

最终 provider 保留了原有无关配置，只调整了鉴权、Responses 协议和图片功能：

```toml
[model_providers.maynoraicodex]
name = "maynoraicodex"
base_url = "https://momoai.asia/v1"
wire_api = "responses"
requires_openai_auth = false
env_key = "OPENAI_API_KEY"
http_headers = { "x-openai-actor-authorization" = "local-relay" }

[features]
image_generation = true
```

主模型仍然使用支持工具调用的 `gpt-5.4`。不要把 Codex 的对话主模型改成 `gpt-image-2`；图片模型由内置工具在需要时调用。

## 一键修复脚本做了什么

仓库里的两份脚本按顺序完成四件事：

1. 重新读取现有 `config.toml`，只合并目标 provider 和 `[features]`，避免重复 section。
2. 清除旧的 command auth 和 Node helper 引用，确保 `env_key` 是唯一鉴权入口。
3. macOS 配置 LaunchAgent；Windows 写入用户级 `OPENAI_API_KEY`，让桌面进程在下次启动时继承。
4. 在不使用 Node 或 Python 的情况下检查 `/v1/models`、`/v1/responses`、`gpt-image-2`、`gpt-5.4` 和配置幂等性。

macOS 实际脚本验证结果为：`shell_syntax=OK`、`models_http=200`、`gpt-image-2=AVAILABLE`、`gpt-5.4=AVAILABLE`、`responses_http=200`、`config_idempotent=true`。Windows 脚本提供同等的配置和接口检查，但仓库没有把 macOS 产物冒充成 Windows 实测。

## 最终验证：让内置工具真的生成文件

接口检查通过后，我们使用 Codex 原生可执行路径对应的桌面 CLI 子进程，注入用户作用域环境变量，创建一次临时任务，并明确要求只调用一次内置 `image_gen`，生成“白底居中蓝色圆形”的诊断图。

验证要求禁止 shell、Python、SVG、Canvas 和外部图片工具。最终内置工具可见并完成调用，产生本地 PNG。随后又生成了一张橘猫图，作为文章中的真实产物示例：

![修复后由内置 image_gen 生成的橘猫](https://upload.maynor1024.live/file/1784724285956_codex-imagegen-result-cat.png)

这张图不是手工绘制，也不是脚本拼出来的；它来自 Codex 内置图片工具的实际输出。

## 安全边界和限制

这次修复解决的是 provider 配置、鉴权注入和工具门控，不代表第三方中转天然可信。中转服务仍可能记录请求、提示词或图片，涉及内部代码、客户资料和未公开方案时必须先确认服务方的数据处理策略。

另一个边界是平台差异：本次完整链路在 macOS 上验证通过，Windows 的 User/Machine 环境变量和桌面进程继承机制不同，不能直接把 macOS LaunchAgent 当成 Windows 修复方案。Windows 应使用对应的用户环境变量写入和新进程验证流程，但原则仍然是“密钥走环境变量，Codex 使用自定义 provider，图片由内置工具调用”。

## 写在最后

我们最后修好的不是某一个“神奇参数”，而是调用链的边界：

```text
工具可见性  <- requires_openai_auth=false + 非空静态 actor header
请求鉴权    <- env_key=OPENAI_API_KEY
接口协议    <- wire_api=responses + /v1
桌面继承    <- 用户级环境变量 + 完全重启 Codex
图片调用    <- 对话模型调用内置 image_gen，再由中转访问 gpt-image-2
```

所以，遇到“Codex 升级后能聊天但不能生图”时，不要先反复更换 API Key。先分别验证模型列表、Responses、provider 门控和桌面进程环境，再做最小修改，通常更快也更安全。

项目地址：<https://github.com/xianyu110/codex-imagegen-relay-fix>
