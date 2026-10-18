# 原生 gRPC 读接口模块

此模块完成原生 ARM64 gRPC 基础与现有读调用协议，尚未接入 UI，也未验证真实 Bilibili 服务。完整 WinUI 项目移植仍在进行。本次没有真实账号、Keychain、评论写入、私信或其他外部写操作。

`NativeBiliRPCService` 与现有 REST `BiliService` 组合，共用同一个 auth actor。未来 UI 调用 `BiliRPCService`，得到 `Sendable/Codable` DTO；protobuf 消息只在协议与网络边界使用。安装 ID 由 composition root 提供稳定值，不使用账号 ID。生产 host 固定为 `grpc.biliapi.net:443`。

| 接口 | 请求／分页字段 | 身份要求 |
| --- | --- | --- |
| `comments` → `Reply/MainList` | oid、type、sort mode、cursor.next | 有效 App Token 可选 |
| `commentDetails` → `Reply/DetailList` | oid、type、root、scene=REPLY、cursor.next | 有效 App Token 可选 |
| `dynamics(.all)` → `Dynamic/DynAll` | offset、update_baseline、refresh_type、local_time | 需要有效 App Token |
| `dynamics(.video)` → `Dynamic/DynVideo` | 同上 | 需要有效 App Token |
| `dynamics(.userAll)` → `Dynamic/DynAllPersonal` | host_uid、offset、local_time | 有效 App Token 可选 |
| `dynamics(.userVideo)` → `Dynamic/DynVideoPersonal` | 同上；响应为 `DynAllPersonalReply` | 有效 App Token 可选 |
| `dynamics(.space)` → `Dynamic/DynSpace` | host_uid、history_offset、local_time | 需要有效 App Token |
| `history` → `History/CursorV2` | business=`all/archive/article/live`、cursor.max | 需要有效 App Token |
| `popular` → `Popular/Index` | idx、ver；nextIndex 从卡片 base.idx 得到 | 有效 App Token 可选 |
| `ranking` → `Rank/RankRegion` | rid | 有效 App Token 可选 |

## Route 与 schema

请求 `MethodDescriptor` 集中在 `BiliRPCMethod`，逐项保留 exact BiliKernel `BiliApis.cs` 的实际调用路径。schema 的 namespace 与 route 存在三处差异：

| 实际 route 的 service | `.proto` 的 service namespace |
| --- | --- |
| `bilibili.app.interface.v1.History` | `bilibili.app.interfaces.v1.History` |
| `bilibili.app.show.v1.Popular` | `bilibili.app.show.popular.v1.Popular` |
| `bilibili.app.show.v1.Rank` | `bilibili.app.show.rank.v1.Rank` |

这些差异来自上游，不是服务可用性的证明。未做 namespace 自动切换或静默 fallback；需要真实联调后以服务结果确认。`CursorV2` 使用 schema 声明的 `CursorV2Req`；原 C# 使用 wire-compatible `CursorReq`，原四个字段号相同。

## 身份与取消

`BiliService.withRPCIdentity` 在 actor 内检查／刷新 Token、检查捕获的 epoch 与 identityRevision、捕获一个 snapshot，并登记 RPC 取消闭包。binary metadata 与 authorization／mid 均取自此 snapshot。每个 RPC 使用独立 Task；取消调用者只取消其 HTTP/2 stream。

logout、beginLogin、恢复／替换身份取消已登记 RPC。refresh 失败先确认仍属原身份，再递增 identityRevision、只取消 RPC、清 Token并发布事件；保留 authEpoch、Web Cookie、HTTP requests 和 refresh flight，所有共享 refresh waiter 保留原失败。迟到成功或失败都重新检查 epoch／revision，失效后返回 `CancellationError`。

`identityEvents()` 使用 `AsyncStream`／`bufferingNewest(1)`，只提供 epoch、identityRevision、state、mid；不广播 Token。内部 invalidate 不发布中间清空 Token 的状态；restore、beginLogin、commit、refresh 成功／失败与 logout 在最外层发布一次最终状态。存储失败也通过 defer 发布最终内存状态；refresh 的嵌套 persist 不重复发布，不取消自身 refresh flight。onTermination 弱引用 actor，actor 销毁结束 stream。事件并非 Token 到期定时器；请求时仍须检查／刷新。UI 尚未订阅这些事件，接线时还需在 UI 提交响应前检查自己的身份／request generation。

## Metadata 与传输

metadata profile 逐字段移植 exact `GrpcConfig.cs`：`build=6070600`、iphone profile、locale zh/CN、Wi-Fi、Fawkes prod、空 Restriction。保留上游 `bili-universal/80200100` user-agent 与 profile build 的差异。header 中的 profile buvid 保留上游常量；外层 buvid 依上游 Buvid 算法从应用安装 ID 派生。完整来源与 hash 在 `Protocols/BiliKernel/manifest.json`。

`x-bili-*-bin` 添加原始 protobuf bytes，由 GRPCCore 在 HTTP/2 wire 上执行一次 unpadded base64；没有把已编码字符串再次编码。匿名或过期状态没有 authorization／mid／access_key。trace 与 aurora eid 按上游格式构建；不记录 header、请求体、Token或服务错误消息。

生产仅选择 `GRPCNIOTransportHTTP2TransportServices`：Network.framework／NIOTS、系统信任 TLS、ALPN h2。未选择 transport umbrella 或 NIOSSL product。`Package.resolved` 仍会记录依赖包自身声明的 Posix／NIOSSL 等传递 package，不代表生产走这些 TLS transport。TLS trust／远程 ALPN 仅核对官方 tag 源码，未进行线上 TLS 联调。

gRPC 库处理标准 5-byte framing、HTTP 状态、gzip／deflate、final grpc-status 和 trailers。20 秒 timeout；请求上限 1 MiB、响应上限 8 MiB（包括解压后）；默认最多 16 个在途 RPC。无自动分页预取、无限缓存或账户之间共用结果缓存。

`shutdown` 先停止新调用、开始 graceful shutdown，再以最多 5 秒 grace（service 默认 2 秒）排空；到期取消在途 stream 和 connections Task，等待连接退出。未启动的 transport shutdown 不启动连接。所有等待均为 async，没有阻塞 MainActor。

## DTO 与支持边界

- 评论：作者、文本、emote、创建时间、like／reply count／liked、置顶与递归 replies、root／cursor；不解析 rich-text 全部子类型、图片、投票等扩展。
- 动态：文本、UGC video、PGC episode、图片、文章、转发、作者、emote、统计、评论 target；其他 oneof 保留 `.unsupported(type:)`，不会丢弃整条动态。递归最多 8 层，单列表最多 512 项。
- 历史：UGC、OGV、文章、直播、课程与 unknown；保留 business／id／viewedAt、progress、next max／hasMore。未实现删除／清空。
- 热门：`small_cover_v5` 仅接受 `base.cardGoto == "av"` 且 URI 不含 `bangumi` 的视频卡；其他卡保留 `.unsupported(kind:)`，非视频卡不解析 aid，存在的 base.idx 仍参与游标。`popularTopEntrance.base.idx` 也参与分页最大 index。bvid 来自 `base.threePointV4.sharePlane.bvid`，数值 duration 来自 `base.playerArgs.duration`，durationLabel 独立保留；views 未解析，保留 0。缺少 continuation 时 nextIndex=nil，不能将其解释为 feed 结束。
- 排行榜：aid、cid、标题、封面、作者、duration、views、uri。上游 schema 无 bvid，DTO 保留空字符串，不伪造 BV ID。

必要字段缺失或格式无效返回 typed `invalidPayload`；服务端权限、未登录、timeout、HTTP／RPC 失败有 typed error。未支持的内容与合法空页面分别表达。未知 error 不向调用者透出可能含凭据的底层消息。

## 生成、来源与验证

22 个递归 `.proto` 原样来自 `Richasy/bili-kernel` commit `22fdf8ca04bab384b46536b05f6524a41f83a2d4`，保留原始 decompiler 头，逐文件 SHA-256 锁定。Google Any 与许可证已对照官方 protobuf `v36.2` bytes。参考 C# 客户端／adapter／metadata 文件的 hash 同时锁定；没有直接照搬其有长度缺陷的手工 HTTP framing。

仅生成 message 源；调用路线由手工 descriptor 绑定，因此不生成与原路线不一致的 client。`protoc-gen-swift 1.39.0`、protoc 36.2 的版本／源 revision／protoc binary SHA 与输出 hash 固定在 `Protocols/{codegen,generated}.lock.json`。grpc protobuf runtime／generator 来源同为 2.4.1；其 generator 已在 ARM64 编译，但不参与当前 message-only 输出。生成文件不手改、不格式化。

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
swift package resolve
python3 scripts/generate_bili_protocol.py --check
# 重新生成：python3 scripts/generate_bili_protocol.py
swift build --arch arm64
swift test --arch arm64
```

脚本校验锁定输入、编译源锁定的 Swift generator，再生成并比较输出／fixture；protoc 的 binary hash 绑定当前工具安装，换工具版本应审查并显式更新锁，不可忽略 hash 差异。构建本身消费已提交生成源，不要求安装 protoc。

2026-10-13 在 macOS 27.0.1／Xcode 27／Swift 6.4／arm64：全量 64 tests，2 个已有真实网络／媒体测试跳过，0 failures；31 个已有 AuthTests 保持通过。新增 11 个 RPC fixture／身份测试与 6 个真实 NIOTS loopback 测试。fixture由独立 protoc 从 fake `.textproto` 生成，未运行 C# runtime；测试只对照 schema bytes 与已核对的 adapter 字段映射。

loopback 实测大于 255 bytes（约 15 KiB）的双向消息、实际 gzip negotiation、binary metadata、HTTP 503、message 后权限失败 trailer、解压后 8 MiB 超限拒绝、并发／请求大小限制、单 stream 取消隔离、100 ms shutdown、未启动即 shutdown。脱敏证据在 `docs/evidence/rpc-module.json`；原始测试 log 在 `.build/rpc-all-tests.log`。

仍未验证：真实服务／账户权限／线上 route 差异、远端 TLS／ALPN、真实消息的全部扩展形态、UI 订阅／接线、完整页面与写功能。没有将本模块的 fixture 通过称为完整移植或线上通过。


## 独立 review 修复验证（2026-10-13）

新增 5 个 fixture tests，覆盖正在等待 next() 的 observer 在 restore／beginLogin／commit 中只收到最终身份、mismatched Cookie 清 Token失败和 logout存储失败仍发布终态、混合非 av／bangumi 卡、非空 bvid／非零数值 duration、末尾 popularTopEntrance 游标。原 refresh failure 测试改为事先等待事件，仍验证共享 refresh waiter 收到原 rejection、旧 RPC 被取消、随后匿名 metadata 无旧 Token。Credential gate 只作用于 fake store，不读写真实 Keychain。

最终 `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --arch arm64`：70 tests、2 skipped、0 failures；RPCTests 16 项、AuthTests 31 项均通过。相关 Swift strict lint、限定 diff whitespace 检查通过。实验的 diagnostics Release 包在这些纯 RPC 修复前封存，后续单独验证最新源的 Swift Release build；媒体 captures 不据此重跑，也不声称该封存包包含 review 后的 RPC 修复。真实服务、UI 和账户链路仍未验证。
