> 开源版本移除了历史截图（含旧名称与旧图标）；表中提到的截图文件可用 `scripts/live_check.sh --fixture` 重新生成。

# 功能对照清单

基准 UI commit `896a06290ba440cb17776d292dff119bbd3383d6`；✅=该行注明的验收范围通过，🚧=仍有缺项或验证条件未满足。截图在 `docs/screenshots/`；fixture通过不等于实网验证。Claude已接受M7/M8主体；完整原版功能仍有未达项，定稿清单见 [KnownIssues.md](KnownIssues.md)，M9实测见 [Performance.md](Performance.md)。

| 原版页面／功能 | Mac状态 | 备注 |
| --- | --- | --- |
| 主窗口/导航/Overlay返回 | ✅ | 实网只读通过（Claude重启后同构建验收）；Overlay按原版保留进入前主导航选中项；64pt栏/透明标题栏/240pt二级面板，compare-popular.png已核对 |
| 浅深主题/卡片/分页/图片缓存 | 🚧 | 实网封面已由f7b3c77统一hdslb HTTP→HTTPS（不放宽ATS）；深浅fixture通过；推荐播放数字段修后待复验 |
| 基础菜单与快捷键 | 🚧 | 浏览收藏/稍后看/历史/消息/下载、播放暂停/快进退/上一下一/弹幕/小窗/全屏/截图、标准Mac隐藏与窗口菜单已接；文本编辑时裸键禁用；228tests通过，实际键盘交互待复验 |
| 扫码/网页登录/凭据恢复 | 🚧 | TV Token与同封存包恢复已验证；新Debug Keychain待用户操作，Web→App转换未验 |
| 推荐/精选推荐 | 🚧 | 推荐实网只读通过；7154fb2播放数映射已于2026-10-14集中实网复验确认；公开feed不含发布时间时留空；精选与媒体EOF未验；recommended.png/curated-queue.png |
| 热门 | ✅ | 实网只读通过；Native App Popular RPC/raw idx分页，新shell；popular-dark.png / compare-popular.png为fixture |
| 排行榜 | ✅ | 全区排行榜实网只读通过；分区排行榜尚待复验；ranking.png为fixture |
| 视频分区/子分区/排序 | ✅ | 动画分区实网只读通过；子分区/各排序与其它分区待复验；partitions.png为fixture |
| 视频播放/信息/分P/合集/相关推荐 | 🚧 | 公开BV1xx411c7mD实网只读播放有画面及弹幕；原版信息/分集/评论布局；分P/合集/相关推荐全路径及真实写未验，video-player-dark.png / video-info-dark.png为fixture |
| App签名播放/匿名WBI fallback | ✅ | 公开BV1xx411c7mD实网只读播放有画面及弹幕（Claude验收）；精确参数/身份绑定与匿名fallback fixture通过；换号播放仍待复验 |
| 清晰度/编码偏好/备用URL | 🚧 | 真实默认播放通过；切清晰度/编码偏好/备用URL组合待复验；元数据/选择/记忆fixture通过 |
| 评论排序/分页/楼中楼 | 🚧 | RPC+最热/最新+800预加载+楼中楼固定时间排序与分页；新shell fixture comments.png；inline表情已接ImageCache；线上RPC未验，新增布局见final-gaps-dark/video.png |
| 点赞/投币/收藏/三连/关注 | 🚧 | expectedIdentity/Core+实际UI状态协调器fixture116tests与review通过；View/ReqUser+Web状态、换号/过期/中断状态恢复；未执行真实账号写操作 |
| 搜索（视频及其它类型） | ✅ | 视频搜索实网只读通过；其它类型/Web fallback/区域搜索待复验；m3-fixture/search.png为fixture |
| 用户空间 | ✅ | 实网只读资料与投稿通过；获赞/等级/VIP资料卡已补，结构fixture通过，新增字段待实网复验；关注写仅fixture；final-gaps-dark/space.png为fixture |
| 关注/粉丝 | ✅ | 关注分组/粉丝实网只读通过；按原版UserCard底部为MID；465e0b2修千分位格式后待复验，写仅fixture；m3-fixture/following.png、followers.png |
| 收藏夹 | ✅ | 追番收藏实网只读通过；其它文件夹/视频内容及多选批处理待验，写仅fixture；m3-fixture/favorites.png为fixture |
| 稍后再看 | ✅ | 实网只读列表通过；多选删除/清空确认仅fixture；m3-fixture/later.png为fixture |
| 历史记录 | ✅ | 实网只读列表通过；其它分类/搜索待复验，删除/清空仅fixture；m3-fixture/history.png为fixture。2026-10-18补齐原版的观看进度上报（`/x/v2/history/report`，视频 type=3、番剧 type=4），请求字段由单测覆盖；自动化测试不写账号，实网写入待使用者观看后在历史页确认 |
| 动态/评论互动 | 🚧 | 视频动态实网只读通过；综合/UP过滤及评论路径待复验，点赞/发送仅fixture+合并review；moment-video-dark.png / moment-all-dark.png / moment-comments-dark.png；inline emote按原版20pt附件/24pt行高接ImageCache，fixture通过，新增布局待实网复验 |
| PGC详情/播放 | 🚧 | 公开ep837204实网只读有画面及弹幕；pgc-player-dark.png / pgc-info-dark.png为fixture；EOF/付费地区待验；追番/追剧、点赞/投币/收藏/三连已接App签名接口、expectedIdentity/CSRF与UI迟到结果隔离，7项fixture+合并review通过；未真实写；信息区按固定XAML移除无有效入口的warning/extra，正文28pt行高，final-gaps-dark/pgc.png为fixture，视觉待实网复验；弹幕发送仅fixture、下载待验 |
| 动漫时间线/索引 | ✅ | 实网索引原报Invalid PGC index list：68c32e3修page0→1，2026-10-14集中实网复验app内索引正常；timeline type2/3合并13天26条无丢失，10-13接口仅1条；0dcb829优先停更pub_index_show；真实结构fixture通过 |
| 影视电影/电视剧/纪录片 | ✅ | 原实网三类均Invalid PGC index list；68c32e3修首page1，2026-10-14集中实网复验app内电影列表正常；cinema-dark.png / cinema-tv-dark.png / cinema-documentary-dark.png为fixture |
| 直播分区/直播入口 | ✅ | 直播推荐和分区实网只读通过；live-dark.png / live-partition-dark.png 为 fixture。2026-10-18 新增 App 内直播播放（超出原版：原版打开网页直播间，右键菜单保留「在浏览器打开」）：web-room v2 getRoomPlayInfo（参数照 BiliKernel），FLV/HLS 线路并发竞速选最快节点，画质切换，看门狗断流自动重连（错误、EOF、画面停止），直播结束检测，实时弹幕（WebSocket，zlib 协议，弹幕叠加在画面上并列在侧栏）、在线和看过人数。匿名实测起播约 3 秒、断流后 5–9 秒恢复；登录态原画与弹幕昵称待使用者授权钥匙串后复验 |
| 专栏阅读与互动 | 🚧 | 推荐/分区子区/6排序/排行榜、native INITIAL_STATE原生正文图片链接+viewinfo合并已接；匿名分区推荐排行/native成功，viewinfo返回-352时保留正文、禁未知互动；点赞收藏/typed12评论楼中楼仅fixture，原版没有投币按钮/API；m6-fixture/article*.png；2026-10-14专栏推荐/排行实网只读通过，正文阅读页待复验 |
| 消息/通知/私信 | ✅ | 回复/@/点赞通知分页、私信会话与历史分页/文本图片撤回、显式发送已接；读取不markread/ack；发送仅fixture，refresh Cookie/CSRF回归与一次合并review通过；m6-fixture/messages-*.png；2026-10-14回复/@/赞/私信实网只读通过；cf869a2补e_infos表情并按原版显示「不受支持的内容」，发送仍仅fixture |
| 下载/合并/任务记录 | 🚧 | 原版画质/编码/分集选项，原生视频音频封面弹幕字幕下载、Range/IfRange恢复/取消/typed磁盘错误/SQLite旧JSON兼容；实际流身份绑定、媒体hash/inode完成记录与换号取消已接，31下载故障tests+5播放导航tests与集中review通过；m7-fixture/downloads*.png；真实媒体/外置跨卷未验 |
| 外部BBDown/命令复制/弹幕导出 | 🚧 | 无凭据Shell正确转义BBDown命令，画质用外部工具格式描述；原始弹幕XML（含特殊模式）/字幕SRT/AI过滤已接，SDK匿名字幕metadata code0样本无tracks；外部工具仅复制不自动执行，实际导出待实网复验 |
| 全量设置/Mac替代项 | 🚧 | 原版App全分组与Mac能力catalog、主题/画质编码/P2P/步进/速度音量/弹幕开关/VideoToolbox/声道/缓存限额/下载/截图保存打开复制/导航/建议/列表边界与推荐策略已接；清图缓存有确认；Windows项不可用。已恢复单列SettingsCard/Expander与应用/AI SelectorBar；长按倍速/弹幕样式/独立窗口/精确跳转/磁盘缓存/CoreAudio独占/自定义mpv/libmpv/profile/导航/滚轮/通知轮询已接；仅四个Windows项禁用；m7-finish-dark/settings*.png，通知重启/换号/点击/迟到投递4fake回归通过；系统授权与实网待复验，AI设置已接 |
| 菜单/快捷键/系统媒体控制 | 🚧 | M7原生菜单与播放快捷键已补、保留文本输入；MPNowPlayingInfoCenter/MPRemoteCommandCenter已接播放暂停/上一下一/进度/封面，实际系统媒体键待使用者复验 |
| AI providers/模型/配置/流式/提示词 | 🚧 | M8 22个原版provider/default endpoint/模型/配置卡已接；17兼容族+Azure OpenAI/Azure AI/Anthropic/Gemini/Ollama独立请求，Ernie BCE Bearer和Codestral独立key；Keychain与公开JSON分离且nonce/目标绑定，单user prompt六模板可编辑；视频总结评价问答/PGC与文章总结评价已接；275tests/2skip/0fail，六族生产URLSession loopback/SSE/NDJSON/UTF8/取消/401/429通过，合并review三P2已闭合；m8-fixture-dark/*.png，仅本地mock未付费调用，Keychain待使用者复验 |
| ChatGPT 套餐（Sign in with ChatGPT，Mac 新增） | 🚧 | 972875f：官方开源流程动态注册/loopback PKCE/JWKS 验签/scope 检查/单飞轮换刷新/撤销；Responses API store:false+stream:true；错误码与 Manage usage；fixture+本地 loopback 测试通过，真实账号登录与一次推理待使用者 |
| Claude（API key） | 🚧 | 972875f：预置改为 Opus 5.5/Sonnet 5.5/Haiku 5.5/Fable 5.1，adaptive thinking+effort、默认拒答回退、refusal 提示、忽略 thinking 增量；订阅 OAuth 按 Anthropic 条款不支持；真实 key 调用待使用者 |
| 内嵌播放器/VideoToolbox/Metal弹幕 | 🚧 | 实网UGC/PGC有画面与弹幕；M9本地60秒4K60两编码验证实际VideoToolbox，数值见Performance；本地性能关闭弹幕，密集弹幕与物理显示完整验收未测 |
| shader菜单 | 🚧 | 冻结现状；ProMax有效播放未验，不再采样 |
| HDR/外屏/睡眠/长期性能 | 🚧 | 300次修复browse引用环/Clipboard/关闭锁反转后无卡死；RSS/活跃MALLOC仍增长未平台，归因边界见Performance；物理HDR、外屏、睡眠和整夜播放缺使用者在场/硬件验收条件；GPU及能耗未测，不使用sudo |
| 视觉截图对照/60fps/4K60目标 | 🚧 | Shell/流行/播放assets+XAML对照已存compare-popular.png/compare-player.png；M9实际600项滚动修正后推荐/搜索无>25ms回调，热门仍1次（0.0556%），不宣称全部稳定60fps；4K60掉帧与测量范围见Performance |
| 独立窗口/外部mpv/字幕/章节/截图 | 🚧 | 同窗口小窗/独立窗口迁移与关闭恢复、字幕选择/AI过滤/本地SRT、mpv章节跳转、截图保存打开复制已接；外部mpv生产IPC本地mock状态/退出与有界取消PASS；m7-finish-dark/video.png、pgc.png；真实媒体及窗口交互待复验 |
| arm64独立app/来源/构建说明 | ✅ | 最终dist/release已重新打包，46arm64最终SHA/依赖闭包/无Homebrew RPATH/strict codesign通过，并实际运行本地性能页；README可照做，替换前stage验证且旧Release备份至.build，其它dist目录禁止写；使用者正式启动/公证范围见KnownIssues |

播放布局核对：原PNG为216dpi（Windows225%）；流行1362×895、播放1426×893逻辑窗口。固定XAML分集Height86/cover120/spacing8用于新实现；旧PNG密度存在版本差异。常规fixture不加载媒体，显式M9性能入口只播放本地素材；UGC/PGC弹幕发送已按SDK POST/身份快照/CSRF接线，写操作仅fixture测试。小窗/全屏按钮实际交互仍待使用者复验。

M2–M8 集中实网验收入口：`scripts/live_check.sh`（同一已构建Debug签名；可加公开 `--video` / `--pgc`）。默认列表包含专栏推荐/排行、四类消息、下载、应用设置和AI设置；不自动生成AI响应。浅色 fixture 抽查存于 `docs/screenshots/m5-light/`。Claude在重启解决cfprefsd崩溃循环后，用同构建完成20页实网只读截图；含个人信息的原图仅存 `.build/live-private/`，不提交。实网通过范围以上表备注为准，✅不涵盖账号写操作。新签名在沙箱无法弹出Keychain授权；改动标待复验，下次用户在场集中跑同一构建。

本轮公开接口核对仅匿名curl与脱敏结构fixture；没有在新签名app内读真实凭据或执行账号写操作。修复页截图位于 `docs/screenshots/read-fixes/`，均为fixture。M6/M7上一阶段228tests（2个明确跳过），本轮M7/M8最终275tests（2跳过/0失败），一次M6写复核与一次M7下载/身份复核均修点闭合；真实页面和真实下载留到同构建集中复验。

M6/M7 浅色抽查存于 `docs/screenshots/m6-m7-light/`；深色设置行为分组补图 `m7-fixture/settings-behavior.png`。36a38b9按原版分P→播放列表→同合集分组→可选相关推荐决策，列表结束策略不作为连播总开关；截图后打开/复制与音量上限控制已接。

待用户在场实网复验（使用同一构建，实网截图仅 `.build/live-private/`）：
- 本次改动后的推荐字段、索引首屏、时间线停更文案、M6专栏/消息与M7下载；不自动执行账号写操作。
- 播放设置：长按倍速、弹幕样式、底部进度、清晰度编码、CoreAudio独占、精确seek、磁盘缓存/profile；字幕AI过滤、章节跳转、截图保存/打开/复制。
- 主/独立窗口迁移与关闭恢复、隐藏主窗口/显示模式、外部mpv实际媒体与退出、真实自定义libmpv、系统媒体键/封面与位置。
- 新ad-hoc签名后的防火墙软件/钥匙串使用者授权，UN通知授权及真实动态轮询/换号清理；全部写操作仍只fixture。
- AI设置的真实Keychain保存/读取/删除；开发验收不得付费调用，生成协议仅本地mock/fixture。实网脚本可打开 `settings:ai`/播放AI tab，不自动生成。
- M9物理HDR/外屏/睡眠恢复、整夜播放和最终Release使用者启动验收；本地4K60与有限生命周期结果已另存Performance。

M7/M8最终截图：`m7-finish-dark/`（设置/行为/mpv/视频/PGC）、`m7-finish-light/settings.png`、`m8-fixture-dark/`（AI设置/视频/PGC/文章）、`m8-fixture-light/settings-ai.png`。M8仅合成响应；真实系统集成未宣称通过。最终Debug build通过；本地mock端口就绪文件改为原子发布后，全套275tests/2skip/0fail。

最终补缺：PGC互动/信息区、空间获赞等级VIP、评论与综合动态inline表情均已补齐；285tests/2skip/0fail，一次合并review及释放修点复查通过。`final-gaps-dark/` 为隔离fixture截图（PGC、评论、视频/综合动态、空间首页）；资料弹出卡未获Computer Use授权，未单独截图，视觉留使用者只读复验。最终Release与300次对照主程序SHA一致，资源释放修点不改变渲染算法。
