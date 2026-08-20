# Codex中转站接入+生图配置——手把手教学版

Codex Desktop 配好了中转，文字对话、写代码都正常，但一让它画图就失败，常见表现是：看不到 `image_gen`、提示鉴权问题，或者任务结束却没有生成图片。

这通常不是“图片模型不存在”，而是中转配置、Codex 内置工具和桌面应用环境变量没有同时对齐。本文基于开源项目完整说明操作：

https://github.com/xianyu110/codex-imagegen-relay-fix

适用对象：已经在 Codex Desktop 中使用 OpenAI 兼容中转，且中转实现了 `/v1/models` 与 `/v1/responses` 的用户。本文提供 macOS 和 Windows 两种操作方式。

## 一、先理解：Codex 生图不是切换聊天模型

不要把 Codex 的对话主模型直接改成 `gpt-image-2`。正确的工作方式是由支持工具调用的对话模型决定何时调用内置图片工具：

```text
对话模型，例如 gpt-5.4
        ↓
Codex 内置 image_gen
        ↓
中转站的 gpt-image-2
        ↓
本地图片产物
```

因此，能聊天不代表图片链路已经打通。至少要同时满足四件事：

1. 中转地址包含 `/v1`，并支持 Responses API。
2. 中转模型列表同时提供可工具调用的对话模型和 `gpt-image-2`。
3. Codex 的自定义 provider 使用环境变量读取 Key，而不是把 Key 固定写进配置。
4. Codex Desktop 新启动的进程能继承 `OPENAI_API_KEY`。

## 二、操作前检查

开始前先确认以下条件：

- 已安装 Codex Desktop。
- 已通过正常登录或既有流程使 `auth.json` 中存在 `OPENAI_API_KEY`。
- `~/.codex/config.toml` 已选择一个自定义 `model_provider`。
- 你的中转站支持 `GET /v1/models` 和 `POST /v1/responses`。
- 模型列表中有 `gpt-image-2`，同时有一个可用于对话和工具调用的模型，例如仓库默认校验的 `gpt-5.4`。

不要把 API Key 粘贴到终端历史、聊天记录、截图、`config.toml` 或文章中。下面的脚本只会报告 Key 是否存在，不会打印 Key 本身。

## 三、最小配置长什么样

脚本会定位当前启用的 `model_provider` 并只改与图片链路相关的字段，最终等价于下面的结构：

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

把 `https://relay.example.com/v1` 替换成你自己的兼容中转地址。`/v1` 不能漏。

这里的 `x-openai-actor-authorization` 是仓库针对当前 Codex 内置工具门控使用的固定占位 header，不是 API Key；兼容中转应忽略或剥离它。真正的请求鉴权来自 `env_key = "OPENAI_API_KEY"`。

如果当前 provider 里同时保留了 `auth = { command = ... }` 或 `experimental_bearer_token`，就可能和环境变量鉴权冲突。脚本会仅在当前 provider 中移除这些冲突字段。

## 四、macOS：一键接入并验证

打开终端，依次执行：

```bash
git clone https://github.com/xianyu110/codex-imagegen-relay-fix.git
cd codex-imagegen-relay-fix
chmod 700 fix-codex-imagegen-macos.sh
./fix-codex-imagegen-macos.sh
```

脚本默认使用：

```text
https://momoai.asia/v1
```

如果你使用其他兼容中转，不需要修改脚本，运行时覆盖即可：

```bash
CODEX_RELAY_BASE_URL='https://relay.example.com/v1' ./fix-codex-imagegen-macos.sh
```

macOS 脚本会从 `$CODEX_HOME/auth.json` 或 `~/.codex/auth.json` 读取已有 Key，然后安装用户级 LaunchAgent。它的目的不是保存 Key，而是在用户登录后将 Key 注入 launchd，使之后启动的 Codex Desktop 可以继承该变量。

出现以下关键输出，说明配置与中转接口检查通过：

```text
OPENAI_API_KEY(auth.json)=EXISTS
OPENAI_API_KEY(macOS user launchd)=EXISTS
provider_config=OK
models_http=200
gpt-image-2=AVAILABLE
gpt-5.4=AVAILABLE
responses_http=200
image_generation_config=READY
```

## 五、Windows：PowerShell 一键接入并验证

Windows 不使用 macOS 的 LaunchAgent，而是将 Key 写入当前用户的 Windows 环境变量，供之后启动的 Codex Desktop 继承。

在 PowerShell 中执行：

```powershell
git clone https://github.com/xianyu110/codex-imagegen-relay-fix.git
Set-Location codex-imagegen-relay-fix
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
.\fix-codex-imagegen-windows.ps1
```

如需使用其他中转地址：

```powershell
.\fix-codex-imagegen-windows.ps1 -RelayBaseUrl 'https://relay.example.com/v1'
```

`Set-ExecutionPolicy -Scope Process` 只作用于当前 PowerShell 窗口，关闭窗口后即失效，不会修改系统级执行策略。若企业设备被组策略限制，应先让管理员审核脚本，而不是关闭整个系统的安全策略。

Windows 脚本会读取 `%CODEX_HOME%\auth.json`，未设置 `CODEX_HOME` 时读取 `%USERPROFILE%\.codex\auth.json`。成功后会输出：

```text
OPENAI_API_KEY(auth.json)=EXISTS
OPENAI_API_KEY(windows user environment)=EXISTS
provider_config=OK
models_http=200
gpt-image-2=AVAILABLE
gpt-5.4=AVAILABLE
responses_http=200
image_generation_config=READY
```

## 六、脚本成功后还差最后一步：完全重启 Codex

这一点经常被忽略。脚本已经修改了用户环境变量，但已经运行的 Codex Desktop 进程不会自动刷新环境。

请按顺序执行：

1. 完全退出 Codex Desktop，包括后台进程。
2. 重新启动 Codex Desktop。
3. 新建一个任务，不要继续使用修复前已经打开的任务。
4. 选择支持工具调用的对话模型，例如 `gpt-5.4`。
5. 直接描述你需要的图片，例如“生成一张白色背景、居中蓝色圆形的 PNG”。

Codex 应该通过内置 `image_gen` 调用图片模型，而不是要求你手动把主模型切换为 `gpt-image-2`。

## 七、常见报错怎么处理

### 1. `OPENAI_API_KEY(auth.json)=MISSING`

说明脚本没有在本机 Codex 认证文件中找到非空 Key。先确认自己已完成 Codex 登录或既有的本地认证流程，再重新运行脚本。不要把 Key 作为脚本参数发送，也不要贴进 Issue。

### 2. `gpt-image-2=UNAVAILABLE`

中转的 `/v1/models` 未返回 `gpt-image-2`，或者当前 Key 没有访问权限。需要在中转服务端确认模型路由和账户权限；修改 Codex 配置不能补出缺失的模型。

### 3. `responses_http` 不是 `2xx`

优先检查三项：中转地址是否带 `/v1`、中转是否支持 `/v1/responses`、对话模型是否可用。先让 Responses 请求正常，再排查图片工具。

### 4. 脚本成功，但看不到 `image_gen`

先确认已经完全退出并重启 Codex，然后新建任务。再检查当前选择的是否为支持工具调用的对话模型，而不是把 `gpt-image-2` 当作主聊天模型。

## 八、安全边界：中转可用不等于可信

这个方案修复的是本地配置和调用链路，不会替你判断第三方中转站的安全性。使用中转前应确认其日志、数据保留、计费和 Key 处理方式。涉及未公开代码、客户资料、公司文档或敏感图片时，建议优先使用经过审批的服务。

macOS 的 Key 会进入当前用户 launchd 会话；Windows 的 Key 会进入当前用户环境变量。两种方式都意味着同一用户账户下的新进程可能读取它，因此共享电脑尤其需要保护系统账户和 `auth.json` 文件权限。

## 总结

Codex 中转站接入后无法生图，通常不是单一模型问题，而是下面这条链路有一处断开：

```text
兼容中转 + /v1/responses
        ↓
provider 使用 env_key = OPENAI_API_KEY
        ↓
requires_openai_auth = false
        ↓
image_generation = true
        ↓
新启动的 Codex Desktop 继承用户环境变量
        ↓
工具调用模型通过 image_gen 使用 gpt-image-2
```

按脚本完成检查、完全重启 Codex、在新任务中要求生成图片，就能把“聊天正常但不能生图”的问题拆成可验证的几步。

项目地址：

https://github.com/xianyu110/codex-imagegen-relay-fix
