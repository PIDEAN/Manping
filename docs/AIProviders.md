# AI 服务与订阅套餐

核实日期：2026-10-20。只用匿名公开 GET、官方文档与本地 fixture 验证；没有使用真实 key 或调用付费生成接口。模型可用性、条款和配额可能随服务商调整，点击「获取模型」获取当前账号和地区的目录。

## 能力与目录

| 服务 | 协议／模型获取 | 说明 |
|---|---|---|
| OpenAI、xAI、DeepSeek、Moonshot、Qwen、SiliconFlow、Groq、Together、Mistral、Perplexity 等 | Chat Completions／GET `{base}/models` | API key 使用 Bearer；Azure OpenAI 使用 GET `{resource}/openai/models?api-version=2024-10-21` 和 `api-key`，目录仅参考，推理仍须手动添加部署名称。Azure AI 目录未核实，不发送猜测请求。Ernie 的 IAM access key 不能作为普通 Bearer 目录凭据，当前明确不支持其目录发现。Mistral 启用 Codestral 时没有已核实的专用目录，默认不发请求；只有用户明确填写自定义代理地址时才使用兼容 GET。自定义地址仍受 HTTPS／本机 HTTP 校验约束。并非每个服务都保证提供兼容目录，失败会分类提示 |
| Anthropic | Messages／GET `/v1/models`，`after_id` 分页 | 读取 `max_input_tokens`、`max_tokens`、`capabilities.*.supported`；跳过 retired 模型 |
| Gemini | Google／GET `/v1beta/models`，`pageToken` 分页 | 仅保留 `generateContent`，读取 `inputTokenLimit`、`outputTokenLimit` |
| OpenRouter | Chat Completions／公开 GET `/api/v1/models` | 读取 `context_length`、`top_provider.max_completion_tokens`、`supported_parameters`；列表不发送 key |
| MiniMax／MiniMax M Plan | Chat Completions／GET `/v1/models` | 国际 `api.minimax.io`，中国 `api.minimax.cn`；目录若不开放则手动填官方模型 id |
| 小米 MiMo／Token Plan | Chat Completions／GET `/v1/models` | 预置 v2.6 系列；套餐 cn／sgp／ams 独立地区，`tp-`／`ttp-` 只作格式提示 |
| OpenCode Zen／Go | 按 provider 与精确 model id 分配四种协议／公开 GET `/inference[/go]/v1/models` | 未知 id 用 Chat Completions；同一个 id 在 Zen 和 Go 的协议可能不同；四种推理协议均使用 Bearer；列表不发送 key |
| Ollama | `/api/chat`／GET `/api/tags` | 本机无需 key，tags 不提供可确认的上下文容量 |
| LM Studio | Chat Completions／GET `/v1/models` | 默认 localhost:1234，无需 key；服务器启用认证时可填写可选 Bearer key |
| ChatGPT 套餐／Apple 本地 | 保持既有专用实现 | 不与 API key／OpenCode Responses 的请求策略混用 |

目录最多保存 1000 个模型，整个请求过程最多读取 16 MB，最多 32 页，重复 cursor 会终止；拒绝 HTTP 重定向并支持取消。公开配置保存获取时间及目标地址，地址变更时清除旧目录，读取旧配置时新字段可缺省。容量按用户自定义、服务器、预置依次补齐，不因同名模型丢失服务器容量。自定义模型入口可填写上下文和最大输出，可用同 id 覆盖服务器／预置容量。未知容量沿用保守预算，无法保证自动获得每家服务的真实模型上限。

「获取模型」只发 GET，不调用生成接口。返回成功证明目录可访问，不代表该模型的生成权限、订阅资格、费用或协议已实网验证。改动过但未保存的 endpoint/key 保留在草稿；新地址的目录需保存配置后持久化，获取操作不替换已保存 endpoint 或 key。

OpenCode 使用 `Manping/<版本>` User-Agent。`x-opencode-session` 按本项目简报每次进程启动生成随机 UUID，不含用户信息；官方建议按 conversation 保持稳定，本项目目前采用进程范围。协议映射集中在 `AIOpenCodeRouting.family(provider:model:)`，不根据未知 id 的前缀推测。

Perplexity 原 Sonar Chat Completions 已于 2026-09-27 停止支持，移除旧 llama-sonar 预置，默认改为 Gateway `https://api.perplexity.ai/router/v1`，使用 `/models` 与 `/chat/completions`。该服务为 Private Preview，需申请权限；旧配置中显式填写的地址不会自动迁移；旧默认地址配置的凭据绑定将要求重新确认地址并保存，不会自动把旧 key 发送至新地址。

## 思考与容量

OpenAI 兼容 SSE 的 `delta.reasoning_content` 不进入答案正文；Gemini thought、Anthropic thinking 也不进入正文。分段摘要的 low effort 仅在文档允许时关闭思考：DeepSeek V4、Qwen 五个已核实混合模式 id（qwen3.8-max、qwen3.8-flash、qwen3.7-plus、qwen3.6-plus、qwen3.5-plus）与 SiliconFlow Qwen/Qwen3.6-35B-A3B、智谱旧混合模型、MiMo v2.6；MiniMax M3.1 Flash、GLM-5.3 和 Kimi K3 保持思考，仅降低 effort。未确认的模型不发送猜测的关闭参数。OpenCode 聚合接口不直接套用直连厂商参数。

Kimi K3 的多轮接口要求原样回传 assistant 的完整思考历史；当前不保存这些隐藏内容，因此直连 K3 仅支持单轮，多轮请求会明确拒绝并提示换模型。不会发送不完整历史。MiMo `mimo-v2.5` 与 `mimo-v2.5-pro` 不再预置（官方计划 2026-10-21 10:00 UTC+8 失效）。

新增已核实容量：GPT-6 Astra 1,050,000／128,000；Gemini 3.8 Flash 1,048,576／65,536；DeepSeek Flash／V4 Pro 1,048,576／393,216；GLM-5.3 1,000,000／128,000；MiniMax M3.1 Flash 1,000,000／524,288；MiMo v2.6 三款 1,048,576／131,072。容量数字来自下列模型或 API 参数文档，目录返回的有效容量优先。

预置清理依据：[Groq 退役清单](https://console.groq.com/docs/deprecations)确认 `llama3-70b-8192`、`mixtral-8x7b-32768`、`gemma2-9b-it` 已停用；OpenRouter 匿名公开目录当前未列出 `google/gemini-2.0-flash-thinking-exp:free` 与 `qwen/qvq-72b-preview`，因此移除。`grok-beta`、`grok-2-vision`、`grok-2-latest` 在 [xAI 当前模型页](https://docs.x.ai/developers/models)未列出，但旧静态示例仍有不同说法，无法匿名确认当前可用性，保守移出预置，通过服务器获取；不将它们宣称为已退役。

## 套餐条款结论

| 套餐 | 结论及官方出处 |
|---|---|
| OpenCode Zen | 正式支持，按量付费，可用于其他 agent：[模型表](https://opencode.ai/v2/docs/console/models/)、[Inference API](https://opencode.ai/v2/docs/console/api/inference/) |
| MiniMax M Plan | 可选；文档支持其他工具，但未明确授权本应用场景；卡片顶部固定显示「条款未明确允许第三方应用，风险自负」：[M Plan](https://platform.minimax.io/docs/m-plan/other-tools)、[国内 quickstart](https://platform.minimax.cn/docs/coding-plan/quickstart) |
| 小米 MiMo Token Plan | 可选；条款未明确允许第三方应用，风险自负；[快速接入](https://mimo.mi.com/docs/zh-CN/tokenplan/Token%20Plan/quick-access) |
| OpenCode Go | 可选；面向 OpenCode 与其他 coding agents，本应用非编程场景授权不明确，风险自负：[Go](https://opencode.ai/v2/docs/console/go/) |
| 百炼 Coding Plan | 不支持；限编程工具，禁止自定义后端、自动脚本和非交互批量调用：[条款](https://help.aliyun.com/zh/model-studio/coding-plan) |
| 百炼 Token Plan | 不支持；仅交互式 AI 编程工具，不可作后端服务：[官方说明](https://www.alibabacloud.com/help/en/model-studio/base-url) |
| 智谱 GLM Coding Plan | 不支持；限指定编程工具／产品环境：[使用说明](https://docs.bigmodel.cn/cn/coding-plan/usage-notes) |
| 火山方舟 Coding Plan | 不支持；不能用于普通 API 调用，非 AI 编程工具可能封禁：[官方说明](https://www.volcengine.com/docs/82379/1925114) |
| Kimi Code | 不支持本应用场景；仅个人交互式编程，禁止非交互自动化与身份伪装：[社区准则](https://www.kimi.com/code/docs/en/kimi-code/community-guidelines.html) |
| Claude Free／Pro／Max | 不支持；禁止第三方应用代用订阅凭据：[Authentication 条款](https://code.claude.com/docs/en/legal-and-compliance) |
| Gemini 订阅／CLI OAuth | 不支持；禁止第三方访问 CLI 底层服务／OAuth：[条款](https://geminicli.com/docs/resources/tos-privacy/) |

订阅套餐与按量付费服务分别保存 key。未明确授权的套餐必须由使用者自行判断风险；不会伪装成官方编程客户端。受限套餐引导改用按量付费 API。

## 官方接口与模型出处

- [OpenAI GPT-6 Astra](https://developers.openai.com/api/docs/models/gpt-6-astra)、[模型目录](https://developers.openai.com/api/docs/models)
- [Anthropic Models API](https://platform.claude.com/docs/en/api/models/list)、[模型概览](https://platform.claude.com/docs/en/models/overview)
- [Gemini Models API](https://ai.google.dev/api/models)、[Gemini 3.8 Flash](https://ai.google.dev/gemini-api/docs/models/gemini-3.8-flash)
- [DeepSeek Models API](https://api-docs.deepseek.com/api/list-models/)、[思考模式](https://api-docs.deepseek.com/guides/thinking_mode/)
- [Moonshot Kimi K3](https://platform.moonshot.cn/docs/guide/kimi-k3-quickstart)、[effort](https://platform.moonshot.cn/docs/guide/use-thinking-effort)
- [Qwen API](https://help.aliyun.com/zh/model-studio/qwen-api-via-openai-chat-completions/)、[地区和套餐 base URL](https://www.alibabacloud.com/help/en/model-studio/base-url)
- [智谱 GLM-5.3](https://docs.bigmodel.cn/cn/guide/models/text/glm-5.3.md)、[思考](https://docs.bigmodel.cn/cn/guide/capabilities/thinking-mode.md)、[国际 API](https://docs.z.ai/api-reference/introduction.md)
- [MiniMax OpenAI API](https://platform.minimax.io/docs/api-reference/text-openai-api)、[参数](https://platform.minimax.io/docs/api-reference/text-chat-openai)
- [MiMo 模型目录](https://example-files.cnbj1.mi-fds.com/example-files/configs/model-catalogs.json)、[Chat API](https://mimo.mi.com/docs/en-US/api/chat/openai-api)、[Models API](https://mimo.mi.com/docs/en-US/api/model/list-models)
- [Qwen 混合模式模型表](https://help.aliyun.com/zh/model-studio/deep-thinking)、[SiliconFlow 模型中心](https://www.siliconflow.cn/models)
- [SiliconFlow Chat API](https://docs.siliconflow.cn/docs/api/chat-completions-post)
- [Perplexity Gateway quickstart](https://docs.perplexity.ai/docs/router/quickstart.md)、[Models API](https://docs.perplexity.ai/api-reference/gateway-models-get.md)、[Sonar 迁移](https://docs.perplexity.ai/docs/agent-api/migrate-from-sonar/overview.md)
- [OpenRouter 公开目录](https://openrouter.ai/api/v1/models)、[OpenCode Zen 公开目录](https://opencode.ai/inference/v1/models)、[Go 公开目录](https://opencode.ai/inference/go/v1/models)、[百炼目录 fixture](https://coding.dashscope.aliyuncs.com/v1/models)（百炼仅作解析测试，不接入套餐）
- [LM Studio OpenAI compatibility](https://lmstudio.ai/docs/developer/openai-compat)、[认证](https://lmstudio.ai/docs/developer/core/authentication)、[Ollama tags](https://docs.ollama.com/api/tags)

图标固定来自 MIT 授权 `@lobehub/icons-static-svg@1.95.1`，由导入脚本统一转换 arc flags；商标归各自所有者，不暗示官方合作。详见 `ThirdPartyNotices/LobeHubIcons.md`。
