# 直播互动 UI 场景交接（Unit 3）

本轮未启动 App、未截图、未加载 libmpv 做图，也未执行真实网络／账号写入。以下命令由 Claude 在沙箱外运行；编译、Core 测试与静态检查通过不能替代视觉和键盘验收。

代码源为 `LiveSessionFixture.scenes`：原 14 个名字完整保留，新增 45 个，共 59 个。所有 UI 场景显式返回展示种子，不会落入默认送礼；未知名称会在启动参数校验时拒绝。只有明确的交易／活动 fixture 在虚构 transport 内产生经契约校验的模拟写入。

所有命令使用 `--fixture --in-app-snapshot`；窗口为内容区 points。`settings:*` 捕获设置窗口；全屏场景进入原生全屏，实际截图尺寸由屏幕决定，表中尺寸是进入前的内容区。`effects-reduced` 是局部 fixture 展示覆盖，不改变系统 Reduce Motion。`effects-power` 仅修改进程内 `MemoryPreferences` 的省电偏好。所有直播场景均在 AppModel 构造前选择内存偏好，不读取或重写之前的 Debug／release 配置，场景结束即丢弃。

| 场景 | 设计状态 | 主题 | 窗口 | 示例命令（未运行） |
|---|---|---|---|---|
| `parsing` | 旧解析与二进制样本 | `dark` | 1362×895 | `python3 scripts/live_check.py --fixture --in-app-snapshot --theme dark --window-size 1362 895 --wait 6 --pages live:5000 --app-args '--ui-live-scene parsing' --output .build/live-private/unit3/parsing` |
| `anonymous` | 未登录输入与登录入口 | `dark` | 1362×895 | `python3 scripts/live_check.py --fixture --in-app-snapshot --theme dark --window-size 1362 895 --wait 6 --pages live:5000 --app-args '--ui-live-scene anonymous' --output .build/live-private/unit3/anonymous` |
| `web-only` | 网页身份／App授权边界 | `dark` | 1362×895 | `python3 scripts/live_check.py --fixture --in-app-snapshot --theme dark --window-size 1362 895 --wait 6 --pages live:5000 --app-args '--ui-live-scene web-only' --output .build/live-private/unit3/web-only` |
| `app-authorized` | 已授权虚构账号 | `dark` | 1362×895 | `python3 scripts/live_check.py --fixture --in-app-snapshot --theme dark --window-size 1362 895 --wait 6 --pages live:5000 --app-args '--ui-live-scene app-authorized' --output .build/live-private/unit3/app-authorized` |
| `paid-disabled` | 旧付费关闭场景 | `dark` | 1362×895 | `python3 scripts/live_check.py --fixture --in-app-snapshot --theme dark --window-size 1362 895 --wait 6 --pages live:5000 --app-args '--ui-live-scene paid-disabled' --output .build/live-private/unit3/paid-disabled` |
| `confirmation-required` | 旧超额确认场景，101电池勾选 | `dark` | 1362×895 | `python3 scripts/live_check.py --fixture --in-app-snapshot --theme dark --window-size 1362 895 --wait 6 --pages live:5000 --app-args '--ui-live-scene confirmation-required' --output .build/live-private/unit3/confirmation-required` |
| `gift-success` | 已验证synthetic receipt的已送出卡 | `dark` | 1362×895 | `python3 scripts/live_check.py --fixture --in-app-snapshot --theme dark --window-size 1362 895 --wait 6 --pages live:5000 --app-args '--ui-live-scene gift-success' --output .build/live-private/unit3/gift-success` |
| `rejected` | 明确被拒绝卡 | `dark` | 1362×895 | `python3 scripts/live_check.py --fixture --in-app-snapshot --theme dark --window-size 1362 895 --wait 6 --pages live:5000 --app-args '--ui-live-scene rejected' --output .build/live-private/unit3/rejected` |
| `timeout` | 超时未知卡 | `dark` | 1362×895 | `python3 scripts/live_check.py --fixture --in-app-snapshot --theme dark --window-size 1362 895 --wait 6 --pages live:5000 --app-args '--ui-live-scene timeout' --output .build/live-private/unit3/timeout` |
| `late` | 迟到结果被旧generation丢弃 | `dark` | 1362×895 | `python3 scripts/live_check.py --fixture --in-app-snapshot --theme dark --window-size 1362 895 --wait 6 --pages live:5000 --app-args '--ui-live-scene late' --output .build/live-private/unit3/late` |
| `executedResponseLost` | 已执行但响应丢失的未知卡 | `dark` | 1362×895 | `python3 scripts/live_check.py --fixture --in-app-snapshot --theme dark --window-size 1362 895 --wait 6 --pages live:5000 --app-args '--ui-live-scene executedResponseLost' --output .build/live-private/unit3/executedResponseLost` |
| `risk` | 风控暂停且不自动补发 | `dark` | 1362×895 | `python3 scripts/live_check.py --fixture --in-app-snapshot --theme dark --window-size 1362 895 --wait 6 --pages live:5000 --app-args '--ui-live-scene risk' --output .build/live-private/unit3/risk` |
| `sc-deleted` | 删除标记胜过迟到列表 | `dark` | 1362×895 | `python3 scripts/live_check.py --fixture --in-app-snapshot --theme dark --window-size 1362 895 --wait 6 --pages live:5000 --app-args '--ui-live-scene sc-deleted' --output .build/live-private/unit3/sc-deleted` |
| `lottery-unknown` | 未知活动条件只开浏览器 | `dark` | 1362×895 | `python3 scripts/live_check.py --fixture --in-app-snapshot --theme dark --window-size 1362 895 --wait 6 --pages live:5000 --app-args '--ui-live-scene lottery-unknown' --output .build/live-private/unit3/lottery-unknown` |
| `main` | 富聊天、SC条、双行输入 | `dark` | 1362×895 | `python3 scripts/live_check.py --fixture --in-app-snapshot --theme dark --window-size 1362 895 --wait 6 --pages live:5000 --app-args '--ui-live-scene main' --output .build/live-private/unit3/main` |
| `reply` | 回复与取消回复 | `dark` | 1362×895 | `python3 scripts/live_check.py --fixture --in-app-snapshot --theme dark --window-size 1362 895 --wait 6 --pages live:5000 --app-args '--ui-live-scene reply' --output .build/live-private/unit3/reply` |
| `own` | 自己的弹幕与我标，浅色 | `light` | 1362×895 | `python3 scripts/live_check.py --fixture --in-app-snapshot --theme light --window-size 1362 895 --wait 6 --pages live:5000 --app-args '--ui-live-scene own' --output .build/live-private/unit3/own` |
| `gifts` | 付费锁定的8格礼物与数量 | `dark` | 1362×895 | `python3 scripts/live_check.py --fixture --in-app-snapshot --theme dark --window-size 1362 895 --wait 6 --pages live:5000 --app-args '--ui-live-scene gifts' --output .build/live-private/unit3/gifts` |
| `bag` | 背包、到期时间及数量 | `light` | 1362×895 | `python3 scripts/live_check.py --fixture --in-app-snapshot --theme light --window-size 1362 895 --wait 6 --pages live:5000 --app-args '--ui-live-scene bag' --output .build/live-private/unit3/bag` |
| `paid-locked` | 首次点击锁定提示与打开设置 | `dark` | 1362×895 | `python3 scripts/live_check.py --fixture --in-app-snapshot --theme dark --window-size 1362 895 --wait 6 --pages live:5000 --app-args '--ui-live-scene paid-locked' --output .build/live-private/unit3/paid-locked` |
| `gift-confirm` | 普通金额确认，双Enter需人工验证 | `dark` | 1362×895 | `python3 scripts/live_check.py --fixture --in-app-snapshot --theme dark --window-size 1362 895 --wait 6 --pages live:5000 --app-args '--ui-live-scene gift-confirm' --output .build/live-private/unit3/gift-confirm` |
| `gift-confirm-high` | 101电池额外勾选 | `dark` | 1362×895 | `python3 scripts/live_check.py --fixture --in-app-snapshot --theme dark --window-size 1362 895 --wait 6 --pages live:5000 --app-args '--ui-live-scene gift-confirm-high' --output .build/live-private/unit3/gift-confirm-high` |
| `gift-sending` | 真实fixture发送挂起30秒 | `dark` | 1362×895 | `python3 scripts/live_check.py --fixture --in-app-snapshot --theme dark --window-size 1362 895 --wait 6 --pages live:5000 --app-args '--ui-live-scene gift-sending' --output .build/live-private/unit3/gift-sending` |
| `emotes` | 18格表情与锁定原因 | `dark` | 1362×895 | `python3 scripts/live_check.py --fixture --in-app-snapshot --theme dark --window-size 1362 895 --wait 6 --pages live:5000 --app-args '--ui-live-scene emotes' --output .build/live-private/unit3/emotes` |
| `style` | 颜色／位置／锁定原因 | `light` | 1362×895 | `python3 scripts/live_check.py --fixture --in-app-snapshot --theme light --window-size 1362 895 --wait 6 --pages live:5000 --app-args '--ui-live-scene style' --output .build/live-private/unit3/style` |
| `medals` | 已佩戴／未佩戴／未点亮 | `dark` | 1362×895 | `python3 scripts/live_check.py --fixture --in-app-snapshot --theme dark --window-size 1362 895 --wait 6 --pages live:5000 --app-args '--ui-live-scene medals' --output .build/live-private/unit3/medals` |
| `user-muted` | bool用户禁言与截止时间 | `light` | 1362×895 | `python3 scripts/live_check.py --fixture --in-app-snapshot --theme light --window-size 1362 895 --wait 6 --pages live:5000 --app-args '--ui-live-scene user-muted' --output .build/live-private/unit3/user-muted` |
| `all-muted` | 全员禁言 | `dark` | 1362×895 | `python3 scripts/live_check.py --fixture --in-app-snapshot --theme dark --window-size 1362 895 --wait 6 --pages live:5000 --app-args '--ui-live-scene all-muted' --output .build/live-private/unit3/all-muted` |
| `send-failed` | Core处理真实fixture屏蔽词envelope | `dark` | 1362×895 | `python3 scripts/live_check.py --fixture --in-app-snapshot --theme dark --window-size 1362 895 --wait 6 --pages live:5000 --app-args '--ui-live-scene send-failed' --output .build/live-private/unit3/send-failed` |
| `closed` | 暂未开放提示与结果卡 | `dark` | 1362×895 | `python3 scripts/live_check.py --fixture --in-app-snapshot --theme dark --window-size 1362 895 --wait 6 --pages live:5000 --app-args '--ui-live-scene closed' --output .build/live-private/unit3/closed` |
| `fullscreen` | 全屏共享输入，时间左组 | `dark` | 1362×895 | `python3 scripts/live_check.py --fixture --in-app-snapshot --theme dark --window-size 1362 895 --wait 6 --pages live:5000 --app-args '--ui-live-scene fullscreen' --output .build/live-private/unit3/fullscreen` |
| `sidebar-hidden` | 侧栏收起的控制条输入 | `light` | 1362×895 | `python3 scripts/live_check.py --fixture --in-app-snapshot --theme light --window-size 1362 895 --wait 6 --pages live:5000 --app-args '--ui-live-scene sidebar-hidden' --output .build/live-private/unit3/sidebar-hidden` |
| `anchor-tab` | 主播tab的控制条输入与空间续播入口 | `dark` | 1362×895 | `python3 scripts/live_check.py --fixture --in-app-snapshot --theme dark --window-size 1362 895 --wait 6 --pages live:5000 --app-args '--ui-live-scene anchor-tab' --output .build/live-private/unit3/anchor-tab` |
| `narrow` | 720pt窗口，输入先收起再折叠右组 | `dark` | 720×600 | `python3 scripts/live_check.py --fixture --in-app-snapshot --theme dark --window-size 720 600 --wait 6 --pages live:5000 --app-args '--ui-live-scene narrow' --output .build/live-private/unit3/narrow` |
| `effects` | 礼物／上舰／SC有界队列 | `dark` | 1362×895 | `python3 scripts/live_check.py --fixture --in-app-snapshot --theme dark --window-size 1362 895 --wait 6 --pages live:5000 --app-args '--ui-live-scene effects' --output .build/live-private/unit3/effects` |
| `effects-reduced` | 仅fixture模拟Reduce Motion展示策略 | `dark` | 1362×895 | `python3 scripts/live_check.py --fixture --in-app-snapshot --theme dark --window-size 1362 895 --wait 6 --pages live:5000 --app-args '--ui-live-scene effects-reduced' --output .build/live-private/unit3/effects-reduced` |
| `effects-power` | Debug省电always，无滑入动画 | `dark` | 1362×895 | `python3 scripts/live_check.py --fixture --in-app-snapshot --theme dark --window-size 1362 895 --wait 6 --pages live:5000 --app-args '--ui-live-scene effects-power' --output .build/live-private/unit3/effects-power` |
| `pure` | 纯享不入队，聊天文字保留 | `dark` | 1362×895 | `python3 scripts/live_check.py --fixture --in-app-snapshot --theme dark --window-size 1362 895 --wait 6 --pages live:5000 --app-args '--ui-live-scene pure' --output .build/live-private/unit3/pure` |
| `hide-gifting` | 按钮／礼物聊天／礼物特效同步隐藏 | `light` | 1362×895 | `python3 scripts/live_check.py --fixture --in-app-snapshot --theme light --window-size 1362 895 --wait 6 --pages live:5000 --app-args '--ui-live-scene hide-gifting' --output .build/live-private/unit3/hide-gifting` |
| `lottery-free` | 免费天选明确自动弹幕与关注 | `dark` | 1362×895 | `python3 scripts/live_check.py --fixture --in-app-snapshot --theme dark --window-size 1362 895 --wait 6 --pages live:5000 --app-args '--ui-live-scene lottery-free' --output .build/live-private/unit3/lottery-free` |
| `lottery-gift-required` | 需送礼只提供官方链接 | `dark` | 1362×895 | `python3 scripts/live_check.py --fixture --in-app-snapshot --theme dark --window-size 1362 895 --wait 6 --pages live:5000 --app-args '--ui-live-scene lottery-gift-required' --output .build/live-private/unit3/lottery-gift-required` |
| `lottery-joined` | Core synthetic receipt后已参加 | `dark` | 1362×895 | `python3 scripts/live_check.py --fixture --in-app-snapshot --theme dark --window-size 1362 895 --wait 6 --pages live:5000 --app-args '--ui-live-scene lottery-joined' --output .build/live-private/unit3/lottery-joined` |
| `lottery-award` | fixture开奖名单 | `dark` | 1362×895 | `python3 scripts/live_check.py --fixture --in-app-snapshot --theme dark --window-size 1362 895 --wait 6 --pages live:5000 --app-args '--ui-live-scene lottery-award' --output .build/live-private/unit3/lottery-award` |
| `redpocket-free` | 免费红包及副作用 | `dark` | 1362×895 | `python3 scripts/live_check.py --fixture --in-app-snapshot --theme dark --window-size 1362 895 --wait 6 --pages live:5000 --app-args '--ui-live-scene redpocket-free' --output .build/live-private/unit3/redpocket-free` |
| `redpocket-required` | 需送礼红包只开官方页面 | `dark` | 1362×895 | `python3 scripts/live_check.py --fixture --in-app-snapshot --theme dark --window-size 1362 895 --wait 6 --pages live:5000 --app-args '--ui-live-scene redpocket-required' --output .build/live-private/unit3/redpocket-required` |
| `redpocket-joined` | 已参加红包 | `dark` | 1362×895 | `python3 scripts/live_check.py --fixture --in-app-snapshot --theme dark --window-size 1362 895 --wait 6 --pages live:5000 --app-args '--ui-live-scene redpocket-joined' --output .build/live-private/unit3/redpocket-joined` |
| `redpocket-award` | 红包开奖 | `dark` | 1362×895 | `python3 scripts/live_check.py --fixture --in-app-snapshot --theme dark --window-size 1362 895 --wait 6 --pages live:5000 --app-args '--ui-live-scene redpocket-award' --output .build/live-private/unit3/redpocket-award` |
| `balance-unknown` | 缺wallet.gold显示未知 | `dark` | 1362×895 | `python3 scripts/live_check.py --fixture --in-app-snapshot --theme dark --window-size 1362 895 --wait 6 --pages live:5000 --app-args '--ui-live-scene balance-unknown' --output .build/live-private/unit3/balance-unknown` |
| `unknown-cross-room` | 新房间仍展示原交易room/anchor/gift/amount | `dark` | 1362×895 | `python3 scripts/live_check.py --fixture --in-app-snapshot --theme dark --window-size 1362 895 --wait 6 --pages live:5000 --app-args '--ui-live-scene unknown-cross-room' --output .build/live-private/unit3/unknown-cross-room` |
| `fullscreen-unknown` | 全屏也可见未知卡与核对入口 | `dark` | 1362×895 | `python3 scripts/live_check.py --fixture --in-app-snapshot --theme dark --window-size 1362 895 --wait 6 --pages live:5000 --app-args '--ui-live-scene fullscreen-unknown' --output .build/live-private/unit3/fullscreen-unknown` |
| `sidebar-unknown` | 侧栏收起仍可核对未知交易 | `dark` | 1362×895 | `python3 scripts/live_check.py --fixture --in-app-snapshot --theme dark --window-size 1362 895 --wait 6 --pages live:5000 --app-args '--ui-live-scene sidebar-unknown' --output .build/live-private/unit3/sidebar-unknown` |
| `settings-live` | 直播三节与付费默认关闭 | `light` | 900×800 | `python3 scripts/live_check.py --fixture --in-app-snapshot --theme light --window-size 900 800 --wait 6 --pages settings:live --app-args '--ui-live-scene settings-live' --output .build/live-private/unit3/settings-live` |
| `settings-paid` | 付费开启，阈值可编辑 | `dark` | 900×800 | `python3 scripts/live_check.py --fixture --in-app-snapshot --theme dark --window-size 900 800 --wait 6 --pages settings:live --app-args '--ui-live-scene settings-paid' --output .build/live-private/unit3/settings-paid` |
| `settings-pure` | 纯享开启与逐项开关禁用 | `light` | 900×800 | `python3 scripts/live_check.py --fixture --in-app-snapshot --theme light --window-size 900 800 --wait 6 --pages settings:live --app-args '--ui-live-scene settings-pure' --output .build/live-private/unit3/settings-pure` |
| `sc-fulltext` | SC全文玻璃弹层与chrome固定 | `dark` | 1362×895 | `python3 scripts/live_check.py --fixture --in-app-snapshot --theme dark --window-size 1362 895 --wait 6 --pages live:5000 --app-args '--ui-live-scene sc-fulltext' --output .build/live-private/unit3/sc-fulltext` |
| `reply-hover` | 真实server ID行的回复悬停入口 | `dark` | 1362×895 | `python3 scripts/live_check.py --fixture --in-app-snapshot --theme dark --window-size 1362 895 --wait 6 --pages live:5000 --app-args '--ui-live-scene reply-hover' --output .build/live-private/unit3/reply-hover` |
| `effects-disabled` | 五项分别关闭，纯享仍关闭 | `dark` | 1362×895 | `python3 scripts/live_check.py --fixture --in-app-snapshot --theme dark --window-size 1362 895 --wait 6 --pages live:5000 --app-args '--ui-live-scene effects-disabled' --output .build/live-private/unit3/effects-disabled` |
| `lottery-hidden` | 收起本场天选横幅 | `dark` | 1362×895 | `python3 scripts/live_check.py --fixture --in-app-snapshot --theme dark --window-size 1362 895 --wait 6 --pages live:5000 --app-args '--ui-live-scene lottery-hidden' --output .build/live-private/unit3/lottery-hidden` |
| `redpocket-hidden` | 收起本场红包横幅 | `dark` | 1362×895 | `python3 scripts/live_check.py --fixture --in-app-snapshot --theme dark --window-size 1362 895 --wait 6 --pages live:5000 --app-args '--ui-live-scene redpocket-hidden' --output .build/live-private/unit3/redpocket-hidden` |

## 人工验收与限制

- 对照 Main/Gifts/Compose/Fullscreen/Settings 逐张检查；重点复跑 `main`、`gifts`、`gift-confirm`、`settings-live` 的另一主题，观察窄宽、高额勾选、长文本和未知余额。
- `gift-confirm` 与 `gift-confirm-high` 中实际按主 Return、keypad Enter：均不得送出；只点击确认按钮才调用 actor。另一个窗口的 Enter 不应被确认 view 的局部 monitor 吞掉。点击后 2 秒防重复与原一次性能力仍需实际鼠标验证。
- `fullscreen-unknown`、`sidebar-unknown`、`unknown-cross-room` 只提供「查看消费记录 ↗」和「我已核对」，无重试；消费记录链接打开官方直播个人中心，需用户在页面内选择消费记录。
- 手动从真实直播与UGC/PGC分别检查：共享输入、焦点／弹层固定chrome、更多与播放菜单、小窗无输入；时间与官方章节左组共存。点击UP主名、直播头像与空间按钮仍应转小窗续播后进入空间。
- 设置立即关闭时，检查active/pending特效清空；pure打开时不排队；hide-gifting同时隐藏按钮、聊天礼物与特效。收起本场活动后，新活动id仍可出现。
- 生产写门槛、固定价格白名单与receipt默认均未开放。模拟成功、拒绝、风控、超时／迟到结果，不构成真实接口契约或支付行为验证。

## 新增确定性测试（21 项）

- `LivePresentationTests.testGiftClickGateRequiresTwoSecondsIncludingClockRollback`
- `LivePresentationTests.testIntegerMoneyAndUnknownBalance`
- `LivePresentationTests.testQueueBoundsAdmissionAndImmediatePurge`
- `LivePresentationTests.testConfirmationSuppressesBothEnterKeysOnlyInItsWindow`
- `LivePresentationTests.testReplyUsesServerDanmakuIDAndKeepsSuperChatDeletionSeparate`
- `LivePresentationTests.testMotionPolicyHonorsAccessibilityAndPower`
- `LivePresentationTests.testModerationBooleanMissingExpiryAndAccountBinding`
- `LivePresentationTests.testGiftAggregationKeepsActualValueAndUnknownValue`
- `LivePresentationTests.testRichSceneFixturesUseServerTargetsAndExplicitAvailability`
- `LivePresentationTests.testEntranceNoticeTraversesBinaryDecodeWithoutInventingGiftEffects`
- `LiveInteractionSessionTests.testObsoleteQuoteDismissalCannotRevokeReplacement`
- `LiveInteractionSessionTests.testSuccessfulStyleAppliesToNextSendWithoutReplacingEditedDraft`
- `LiveInteractionSessionTests.testModerationBlocksBeforeTransportAndRoomUnmuteAllowsManualSend`
- `LiveInteractionSessionTests.testUIScenesNeverFallThroughToImplicitGiftAndUnknownNameFails`

- `LiveInteractionSessionTests.testNewExpiredGiftConfirmationCannotInheritAcknowledgedUnknownPresentation`
- `LivePresentationTests.testActivitySnapshotsRejectOutOfOrderRefreshAwardAndRetirement`
- `LiveInteractionSessionTests.testLateUserInfoCannotOverwriteNewModerationNotices`
- `LiveInteractionSessionTests.testMuteDuringPreparationStopsHandoffWithoutReservingLimiter`

- `LiveInteractionSessionTests.testOtherUsersBlockDoesNotDiscardPersonalMuteHTTP`
- `LiveInteractionSessionTests.testRoomUnmuteDoesNotDiscardPersonalMuteHTTP`
- `LiveInteractionSessionTests.testPersonalBlockDoesNotDiscardRoomMuteHTTP`

## 独立复核修复（4 个 P2 与字段关联修正）

- 新确认的展示只接收本次 ticket nonce 对应的状态；上笔 unknown 即使已核对仍留在 actor，也不能令新报价过期后的卡片永久显示发送中。未发放 ticket／未 handoff 的失败结束本次发送展示，原待核对记录不变，不提供重试。
- 初始活动信息与 START/END 刷新共用 `LiveActivitySnapshot` 与递增 request revision。所有 await 返回后检查房间/lifetime 与 request revision；旧响应不能复活旧活动。匹配 kind/id 的 AWARD 和 retire 使挂起读取失效。fixture 初始展示仍等待其活动读完成。
- Core moderation 对个人与全员禁言分别维护单调 revision；用户信息 GET 捕获两者快照，各字段只在对应 revision 未变化时应用。ON/OFF 只使房间字段失效，匹配当前账号的 BLOCK 只使个人字段失效，他人 BLOCK 不使本账号快照失效，reset 同时使两者失效。挂起 GET 与事件竞争的回归测试不使用实网或 wall-clock sleeps。
- 字段关联的补充挂起 GET 测试覆盖：他人 BLOCK 仍采纳本人的 HTTP 禁言；房间 OFF 仍采纳个人禁言；本人的 BLOCK 仍采纳全员禁言。原来的旧快照不能清除较新禁言／解禁测试保持不变。
- 弹幕在 actor handoff 时同步再次检查禁言，位置在 limiter reservation 之前。挂起 prepare 后注入禁言可证明 transport 为零；随后同一草稿在同一 clock 下手动解禁发送成功，证明没有误占限流额度。

## 本地验证与交付记录

- `2385b8a`：build 通过；717 tests，5 skipped，0 failures；privacy 0 findings。日志 `/tmp/live-unit3-2385b8a-{build,test,privacy}.log`。
- `54421f6`：build 通过；725 tests，5 skipped，0 failures；privacy 0 findings。日志 `/tmp/live-unit3-54421f6-{build,test,privacy}.log`。
- `273e1a2`：build 通过；726 tests，5 skipped，0 failures；privacy 0 findings。日志 `/tmp/live-unit3-273e1a2-{build,test,privacy}.log`。
- 独立复核修复 commit 的同组三检查日志按最终 hash 保存，结果见交回报告。新增文件 `swift-format lint --strict` 通过；既有大文件保留原排版，只有新增／改动代码范围格式化。整文件 strict 会报告原有分号、长行等基线约定，未为其改写其他功能。
- 中间检查发现新设置文案缺句末标点，已补齐，未放宽原测试；也收回了整文件format噪声，并修复恢复排版时误改的声明关键字。最终只保留通过检查的本地主题commit，不push、不merge。
- 视觉、窗口事件与真实契约的未验证项见上文和 `KnownIssues.md`；没有用户指出功能遗漏后返工或真实账号变更。开始到最终通过的总耗时与等待时间由主agent结合会话记录汇总，未用tokens/s推断效率。

## 视觉修正：单流弹幕与礼物展示

- 弹幕的勋章／大航海 attachment、昵称、中文冒号、灰色回复对象和正文在同一个可选择 TextKit 流内自然换行；房间大表情仍独立下一行。正文仍复用 `RPCEmoteTextSegment` 与原图片缓存，其他页面未启用 live header。
- 输入区首位显示真实已佩戴勋章与 chevron；无佩戴数据时显示「未佩戴」。第二行采用礼物、点赞、Aa 样式和屏蔽送礼胶囊，控制条继续使用紧凑图标模式。
- 在线／看过／点赞仅采纳相应 socket 消息；fixture 经生产 packet decode 提供三个计数，不把人气作为在线数。礼物配置保留 `img_basic`／`webp` 原值并选择合法图片 URL；本地 fixture 没有真实图片时继续使用 symbol。
- 特效改为 44pt 横向渐变 Capsule、36pt 头像、34pt 礼物图和白色大号斜体数量；guard 使用蓝色，SC 使用价格色并保留正文预览。真实 event 和 giftConfig 提供图片，缺失时才显示 symbol。队列上限、设置 admission、异步旧回调保护和动态效果策略保留。
- 数量档位使用 `String(count)`，1314 不再通过 SwiftUI 本地化成 1,314。取消为 outline Capsule，确认以琥珀 Capsule 明示「送出 N 电池」，高额未勾选使用深琥珀禁用态。
- 需重新截图：`main`、`reply`、`own`、`medals`、`gifts`、`bag`、`gift-confirm`、`gift-confirm-high`、`hide-gifting`、`effects`、`effects-reduced`、`effects-power`。`effects` 的原队列按 gift100、gift101、guard、SC 顺序各展示约 4 秒，可在连接事件后约 2／6／10／14 秒分别核对；启动与解码耗时需在沙箱外确认。编译和 Core 测试不能代替真实键盘、窄宽、图片加载和视觉验收。

## 场景隔离与重新验收

- `PreferencesStore` 使用组合实现：正常 DEBUG／Release 的 provider 仍是 `UserDefaults.standard`，Debug bundle domain 就是 `io.github.pidean.manping.debug`，绝不能创建以自身 bundle identifier 命名的 suite（该构造会返回 nil）。性能诊断保留原独立 suite；直播 UI 场景使用没有任何 UserDefaults 后端的 `MemoryPreferences`，不以随机落盘 suite 再删除模拟隔离。
- 原始参数含 `--ui-live-scene` 就在 AppModel 初始化前选内存 store，未知名称或缺值也不会先写用户配置。内存种子无通知，后续 typed／URL 写入与 remove／register 只更新字典，变更通知在锁外投递到 main queue。MacSettings、ProxySettings、CDNStore 和 App 中现有 provider 使用者共用这个对象；搜索框的 installation ID 也写入该 provider。没有清空或重写用户原有偏好。
- fixture 可达的 shell／live player 侧栏使用显式 State／Binding 与内存通知同步；正常窗口继续使用 AppStorage。`defaultAppStorage` 仅接收实际持久 UserDefaults，fixture 设置没有依赖 AppStorage 写回。主窗、设置窗与独立播放窗均禁用 fixture frame autosave；两类置顶 store 也注入同一 provider，fixture 内点击置顶不写用户的置顶数据。
- 59 个场景完整保留；只有 `sidebar-hidden`、`fullscreen`、`narrow`、`fullscreen-unknown`、`sidebar-unknown` 默认收起右侧栏，其余显式展开。`settings-live`／`settings-paid`／`settings-pure` 启动目标直接映射 `settings:live` 并执行 `openSettings(.live)`，不依赖截图 getter 的副作用。
- `medals` 由实际勋章按钮独占 popover presenter；按钮挂载且 metadataReady 后才展开，root host 排除该类型。控制条输入 popover 内打开勋章时保留其父输入层，避免刚打开就销毁 presenter。此前的 root presenter 时序和污染的隐藏侧栏均可能令截图看不到菜单，实际视觉仍需沙箱外复核。
- 需补拍 `settings-live`、`settings-paid`、`settings-pure`、`medals`，并独立重启执行 `sidebar-hidden` → `main`、`fullscreen` → `medals`、`settings-pure` → `settings-live`，验证侧栏、勋章菜单与设置值不串场；无新增 scene 名称。主 Return／keypad Enter 与点击门禁仍需按上一节人工检查。
- 验证：`c211de4` build 通过，735 tests／5 skipped／0 failures，privacy 0 findings；本主题记录见最终 commit hash 对应的 `/tmp/live-ui-fix-<hash>-{build,test,privacy}.log`，另执行一次 Release build 验证编译分支。新 Core 偏好测试覆盖 typed／URL、两实例与 standard 未污染、通知 main queue、无效参数提前隔离、全部场景默认目标和设置／代理存储注入。

## 收尾复核与本轮新增测试

- 独立复核补齐两处隔离边界：主播信息／shell 可达的 `PinnedLiveStore`、`PinnedUserStore` 改用注入的 `PreferencesStore`；独立播放窗关闭 fixture frame autosave。正常 store 仍由 `.standard` 提供，原置顶字段清洗不变。礼物／guard／SC 的 effect metadata 统一拒绝空或相对头像 URL，只接受合法 http(s) URL，缺图回退到 symbol。
- 补验：`main` →「主播」→点击置顶、切换独立播放窗（⌥⌘P），退出 fixture 后确认正常 Debug 的置顶与窗口记录未变；再重启 `main` 确认仍为独立默认状态。仅沙箱外实际点击和截图可以验证窗口／popover 呈现。本轮没有启动 App、生成截图或执行真实账号写入。
- `87782b5`：build／Release build 通过，743 tests／5 skipped／0 failures，privacy 0 findings；收尾 commit 的同组日志仍按最终 hash 保存。源码中没有 `UserDefaults` subclass 或随机 fixture suite，59 个 scene 名称保持不变。

本轮新增 10 项测试（收尾断言补入既有测试，不新增样式镜像测试）：

- `LivePresentationTests.testGiftArtworkSurvivesRoomIntersectionAndFallsBackToWebP`
- `LivePresentationTests.testPresentationCountersTraverseProductionPacketDecode`
- `LiveFixturePreferencesTests.testMemoryStoreTypedReadsRegistrationAndRemoval`
- `LiveFixturePreferencesTests.testMemoryStoresCannotWriteStandardOrShareValues`
- `LiveFixturePreferencesTests.testMemoryStoreNotifiesWithUpdatedValues`
- `LiveFixturePreferencesTests.testBackgroundMemoryChangeNotifiesOnMainAfterCommit`
- `LiveFixturePreferencesTests.testPreferenceProtocolKeepsNativeUserDefaultsReads`
- `LiveFixturePreferencesTests.testMalformedSceneArgumentsStillRequireMemory`
- `LiveFixturePreferencesTests.testSettingsAndProxyCommitsUseOnlyTheInjectedMemoryStore`
- `LiveFixturePreferencesTests.testAllScenesSpecifyIndependentSidebarAndSettingsTargets`
