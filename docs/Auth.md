# 原生认证链路

源码基准为 BiliCopilot `896a06290ba440cb17776d292dff119bbd3383d6` 与 NuGet `0.0.2-preview2` 声明的 BiliKernel `22fdf8ca04bab384b46536b05f6524a41f83a2d4`。Authorizers.TV/Core snupkg 的 SourceLink 指向同一 commit；本次重新比较七个认证/模型文件与本地 e26f snapshot，字节一致。`BiliApis.cs` 整体有差异，下面的 Passport endpoint 从 exact 22f 源码重读；各原文件 SHA256 见 `Dependencies.lock.json.biliKernelNuget.authenticationSource`。

| 请求 | 参数与行为 |
| --- | --- |
| POST `/x/passport-tv-login/qrcode/auth_code` | `local_id`，每个 service 一个无连字符 GUID；禁止旧 `access_key` |
| POST `/x/passport-tv-login/h5/qrcode/confirm` | `auth_code`、匹配 Passport URL 的 `bili_jct` 作为 `csrf`、手工 Cookie header；禁止旧 Token |
| POST `/x/passport-tv-login/qrcode/poll` | `auth_code`、`local_id`、每次生成的 `guid`；禁止旧 Token；86039/86101 等待、86090 已扫码、86038/-3 过期 |
| POST `/api/oauth2/refreshToken` | 旧 `access_token`、`refresh_token` 和签名参数中的 `access_key`；成功替换 Token |

所有 App POST 按 `BiliAuthenticator.Extension.cs` 添加 `build=80200100`、公开 App key、`mobi_app=iphone`、`platform=ios`、Unix 秒 `ts`，将未编码 `key=value` 排序连接并附 App secret 做 MD5，随后单独 form-urlencode。`expires_in` 是 TTL，保存时转为 Unix 到期秒并拒绝非正值及溢出。成功模型包含 `mid/access_token/refresh_token/expires_in/cookie_info`；Token Cookie name/value 映射为安全的 `.bilibili.com` Cookie，与上游 resolver 的 Bili-wide 行为一致。

`beginQR/pollQR` 保留调用签名，默认 QR 改为原 UI 使用的 TV 协议。`beginWebQR` 保留显式 Web QR 入口。`synchronizeCookies` 保存有效 Web Cookie，清除旧 App Token，调用方再以 `authorizeWebCookies` 完成 TV 确认/轮询；转换失败保留 Web 登录并明确显示“仅 Web 登录”。`ensureAppToken` 对过期 Token 做 single flight refresh，最多重试一次 transport 失败，不重试服务器拒绝。取消一个 waiter 不影响其他 waiter，最后一个 waiter 取消会取消 transport；logout 始终取消整个 flight。

REST 扩展入口 `appRESTParameters` 输出含 `access_key` 的 App form。`AuthSnapshot` 明确区分 `needsLogin/webOnly/appAuthorized`，仅有效 Token 提供 `authorization: identify_v1 …` 与 `x-bili-mid`。原生 gRPC 模块已实现 protobuf device/metadata/network 等 header，并通过 `withRPCIdentity` 原子捕获身份、取消在途 stream 和核对响应。`identityEvents()` 只发布 epoch／identityRevision／state／mid，使用 `bufferingNewest(1)`；UI 接线与真实服务验证尚未完成，见 [RPC.md](RPC.md)。

Cookie jar 属于 service，不使用 `HTTPCookieStorage.shared` 或 `URLSession.shared`。URLSession 禁用自动 Cookie、全局 credential storage/cache/additional headers，保持系统默认 TLS 校验并拒绝自动 redirect；只有匹配 Bili domain/path/secure/expiry 的 Cookie 能手工注入，Set-Cookie 还需属于响应 host 的 Bili domain。response 接受前检查 cancellation 和 auth epoch；logout 先递增 epoch、取消任务，再清空内存及持久化。服务器错误仅展示静态说明和数字 code，不输出 secret-bearing message/body。

Cookie Keychain service 保持 `io.github.pidean.manping.cookies` 和旧 JSON 格式；Token 独立存入 `io.github.pidean.manping.token.v1`，保持已有 `AfterFirstUnlockThisDeviceOnly` 设置，不削弱 ACL、不迁移或通过 shell 读取旧项目。WK 使用 `.nonPersistent()` data store，从 service 同步 Cookie；dismantle/logout 关闭 sheet 时取消 callback/task 并清理该隔离 store。AppModel 的 generation 和 service epoch 双重拒绝迟到账号结果。

验证：`DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test`，认证 fixture 31 项，完整 41 项（2 个 opt-in live/FFmpeg test 跳过），0 failures；相关 `swift-format lint --strict` 与 scoped `git diff --check` 通过。fixture 验证 fake-key 签名向量、form、TTL/溢出、QR 状态、无末尾分号 CSRF、refresh single flight/有限重试/cancellation、持久化纯编解码、Cookie 过滤、logout 与迟到 request/QR/refresh/WK Cookie/account、UI callback generation。WK 实机登录、此次新增 Token Keychain 存取和恢复、真实 TV/refresh endpoint 仍未验证；没有真实 Keychain 操作或发布账号内容。主 agent 已在旧 `dist/gate` 确认用户手动授权后的旧 Cookie 重启恢复，这不构成新 Token 链路验证。

独立 review 修复：身份替换使用独立 `identityRevision`，不改变当前 QR epoch；旧 refresh 的成功、失败和 Cookie 接收均被隔离。Web QR 成功与 WK Cookie 同步统一先取消旧 flight、清旧 Token，再提交新 Cookie。TV Token 提交遵循相同顺序，Token 写入失败保留新 Web Cookie、内存不恢复旧 Token；旧 Token 清除失败不写新 Cookie。存在 `DedeUserID` 时提交及恢复均校验 `token.mid`，拒绝混合身份。waiter 的取消检查与登记在同一锁中原子执行，旧 flight 清理仍检查 flight identity。新增受控测试覆盖 A→Web QR B、同 epoch A refresh 迟到成功/失败及其对 B App Token 的影响、Token 第二次存储失败、旧 Token 清除失败、恢复一致性和 last waiter 取消/新 waiter 登记的精确线程交错。真实 OS prompt 取消路径尚未验证。
