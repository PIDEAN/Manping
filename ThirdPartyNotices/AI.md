# AI configuration and protocol reference sources

The macOS implementation follows the 22 chat providers registered in BiliCopilot UI commit `896a06290ba440cb17776d292dff119bbd3383d6`, including `GlobalDependencies.cs`, `Extensions/ChatConfigManager.cs`, `SettingsPage.xaml` and `AIViewModel`.

- Richasy.AgentKernel NuGet `0.0.8-preview5`: the package repository metadata pins [agent-kernel commit 6d0f0af](https://github.com/Richasy/agent-kernel/tree/6d0f0af68dcce2d1549bed7d77d6104ce622f763). Provider JSON keys, public model fields, default endpoints, predefined model lists and BCE signing follow that source. The MIT license is preserved in `AgentKernel-LICENSE`.
- Richasy.WinUIKernel.AI NuGet `0.0.12-preview3`: repository metadata pins [winui-kernel commit cbb718b](https://github.com/Richasy/winui-kernel/tree/cbb718b94078901c6c66b4c91df0bb9c0e9ae805). Its settings/configuration call chain defines the layout and provider configuration fields. No Windows AI binary is bundled.
- The six default prompt templates follow the GPL-3.0 BiliCopilot `PromptConstants.cs`; editing retains a single user prompt and the original subtitle/hot-comment context rules.
- Gemini uses the supported `x-goog-api-key` HTTP header to avoid putting credentials in URLs; see [Google Gemini API reference](https://ai.google.dev/api).

Keychain records are separate from public `ChatClientConfiguration.json`. The macOS metadata adds presence flags and a transaction nonce; the Keychain record binds that nonce and destination configuration. Fixture tests use synthetic keys and local-only HTTP servers. No paid provider call was performed during implementation.
