# Live contracts

Unit 1 provides read models, candidate request contracts and synthetic fixtures. No authenticated
request has been captured, no production mutation is enabled. `LiveMutationGate()` denies every
POST before preparation or transport. Injected gates are for contract fixtures and, after captured
evidence, the independently reviewed interaction session in Unit 2. A route is not a payment
confirmation, authorization credential or replay mechanism.

Evidence date: 2026-10-20. User-provided research in `live-interaction/research/report.md`,
BLTH `blth_api.ts`, PiliPlus `pp_live.dart`, and BAC documents are community evidence only.
The prior anonymous research verified giftConfig, roomGiftList, DM config and SuperChat list.
The lottery endpoint is a community candidate until an anonymous check succeeds. All login
only reads retain unknown fields and use safe defaults; missing danmaku length stays unknown.

All route hosts are `https://api.live.bilibili.com`. Origin is `https://live.bilibili.com`,
Referer is `https://live.bilibili.com/`, POST forms use `application/x-www-form-urlencoded`.
`LiveRoute` declares the complete path, allowlisted query/body fields, required fields, defaults,
CSRF placement and response policy per route. WBI signs only query fields, including query CSRF,
not the form. Caller captures `AuthSnapshot`; preparation awaits, send and response application
recheck epoch/revision. Cookies and CSRF match the target URL. Identity changes cancel in-flight
transport; mutations are never retried.

| Route | Method | Query/signature | CSRF | Evidence / response policy |
|---|---|---|---|---|
| infoByUser | GET | room_id | none | community; code 0 |
| dmConfig | GET | room_id | none | prior anonymous verification; code 0 |
| emoticons | GET | platform, room_id | none | community; code 0 |
| roomGiftList | GET | platform, room_id, area_parent_id, area_id | none | prior anonymous verification; code 0 |
| giftConfig | GET | platform, room_id | none | prior anonymous verification; code 0 |
| bagList | GET | t, room_id, mobi_app, receive_users, web_location; WBI | none | community; code 0 |
| superChatList | GET | room_id | none | prior anonymous verification; code 0 |
| lotteryInfo | GET | roomid | none | community; code 0 |
| medalPanel | GET | page, page_size | none | community; code 0 |
| danmuInfo | GET | id, type, web_location; WBI | none | existing playback + community; code 0 |
| sendDanmaku | POST | web_location; WBI; message/style/reply fields in form | form csrf + csrf_token | community; code 0 AND empty message |
| setDMConfig | POST | room_id + exactly one of color/mode in form | form csrf | community; code 0 |
| sendBag | POST | all fields in WBI query; empty body | query csrf | BLTH community; code 0; Unit 2 needs business receipt |
| sendGold | POST | web_location WBI; gift fields in form | form csrf + csrf_token | **conjectural**; code 0 + total_coin and gift_list still requires Unit 2 receipt checks |
| like | POST | all fields in WBI query; empty body | query csrf | **conflicting sources**: BLTH query chosen for fixture; PiliPlus form; code 0 |
| wearMedal | POST | medal_id in form | form csrf + csrf_token | community; code 0 |
| takeOffMedal | POST | no user fields | form csrf + csrf_token | community; code 0 |
| joinLottery | POST | room_id, id, platform in form | form csrf | community; business success unknown, accepts() always false |
| drawRedPocket | POST | uid, room_id, ruid, lot_id, ts in form | query csrf | community; business success unknown, accepts() always false |

Keep the raw envelope bytes, code, message and data on all HTTP 2xx responses, including nonzero
API codes. `checkedData` applies each route's response policy; callers of mutations must retain
ambiguous outcomes. HTTP 412/429 and API -352 are terminal risk control, never reasons to replay.
Gold gift `price` is gold seeds: 100 gold seeds = 1 battery = ¥0.1. Display price must not stand in
for actual `total_coin`. Only room-panel gifts are offered after merging global metadata.

## Synthetic validation and handoff

`LiveContractFixture` uses only `fixture-live-*`, uid 900001, synthetic WBI keys (all zeroes/all
ones), and fixture.invalid hosts. It validates method/URL/field placement/headers/WBI/CSRF before
simulating success, rejected, timeout, late, or executedResponseLost. DebugUITransport delegates
the same routes to it; fixtures never fall through to real transport.

`python3 scripts/live_readonly_check.py --dry-run` prints the fixed GET allowlist. Running without
--dry-run performs anonymous requests without a cookie jar, rejects redirects, limits bodies,
prints only public field names and array counts, and stops on risk control. It does not alter
`scripts/api_check.py` or broaden its allowlist.

Contract tests: `LiveRouteTests.testEveryRouteContractAndCSRFPlacement`,
`testAllMutationGatesAreClosedBeforeTransport`, `testMissingCSRFAndWrongDomainNeverSend`,
`testStaleIdentityAndForeignUIDNeverSend`, `testRawEnvelopeAndLargeIdentifiersRemainExact`,
`testReadModelsAndRoomGiftIntersection`, `testFixtureRejectionTimeoutLateAndExecutedResponseLost`,
`testUnknownFieldsAndAmbiguousStyleAreRejected`.

User capture still required for **every POST**, its success business receipt, reply/emote variants,
style permissions, like parameter location, sendGold signature/body, and activity side effects.
Do not collect Cookie values, full HARs, CSRF values or private text. Never trigger writes merely
to provoke errors. Paid gift setting and one-time credentials belong to Unit 2 and remain required
before a production purchase is reachable.

Anonymous check in this worktree (2026-10-20, room parameter 6): giftConfig code 0,
966 catalog items; roomGiftList code 0 with gift_data/gift_config/global_config (room list is
nested at gift_data.room_gift_list); DM config code 0 with 3 groups and 3 modes. SuperChat
returned code -1, lottery returned -352; the checker stopped immediately. No retries or
writes were made. These responses do not verify login-only or mutation contracts.

## Chat parsing

`event()` returns a batch. SEND_GIFT_V2 uses generated SwiftProtobuf 1.39.0 code from the subset
in `Protocols/live/gift.proto`, fixed to [blivedm 3bf17fe862b8c2fc6bc04c81c3f0c5db95de93d6](https://github.com/xfgryujk/blivedm/blob/3bf17fe862b8c2fc6bc04c81c3f0c5db95de93d6/blivedm/models/pb.py).
The repeated gift_list is field 10; total_coin is field 7; field 12 is called rnd in this source
(another frontend schema calls it batch_combo_id). Local safety limits: 1,400,000 base64 bytes,
1 MiB protobuf, nesting depth 16, 1024 gifts. Corrupt input produces an empty batch.
DANMU retains uid, medal, guard, extra emotes/reply/id/type, room emote and timestamp. Other
new commands retain raw public data rather than guessing unknown activity conditions.
Core gift aggregation deduplicates uid/gift/server-ID before summing; no server ID means no
invented duplicate key. Groups last 5 seconds, with bounded 4096 IDs/groups. The reducer persists
across reconnects and resets with room/identity. SC server id/start/end and deletion IDs survive.

New parsing tests (`LiveParsingTests`): testDanmakuMedalEmotesReplyAndTimestamp,
testV2RepeatedGiftsAndExactFieldNumbers, testMalformedAndOversizedProtobufReturnEmpty,
testV1V2DedupBeforeAggregation, testGiftWindowIdentityAndOverflowBounds,
testNoServerIDDoesNotInventDeduplication, testSuperChatServerIdentityTimesAndDeletion,
testGuardLikeModerationLotteryAndRedPocketCommands, testSyntheticBinaryFixtureUsesProductionDecodeChain.

Debug launch scenes (always add `--ui-fixture` and navigate to a live room):
`--ui-page live:5000 --ui-live-scene parsing|rejected|timeout|late|executedResponseLost|risk`.
These show decoded text or an explicit synthetic status in the existing chat area, without
loading media or opening a socket. No Unit 3 visual design or real interaction is enabled.
The same outcome names select the validating POST fixture transport for future Unit 2 flows.

Follow continues to require the existing App authorization path. Unit 1 adds no Cookie-only
follow route. Paid gifts remain unreachable until Unit 2 implements both the default-off paid
gift setting and one-time confirmation credentials.

## Connection and identity validation

`LiveChatClient` injects `LiveChatSocketFactory` and a cancellable clock. Its throwing stream
classifies authentication, -352/HTTP412/429, timeout, network and exhausted-budget errors.
Hosts are tried in endpoint order and wrapped only within the same finite `LiveChatBudget`.
Endpoint preparation failures consume that same budget. Receiving events never resets it.
The default is six connection/preparation attempts; auth handshake timeout is 10 seconds,
reconnect delay 3 seconds, heartbeat 30 seconds. Risk/auth refusals and malformed auth do not
fall back. Timeout explicitly cancels the socket to unblock noncooperative receive; cancellation
and cleanup operate only on the owning generation. Identity is rechecked after preparation,
authorization, every receive/send, retry delay and before delivery. App identity events rebuild
the chat session; stale tasks cannot clear a replacement. The reducer survives socket reconnects.

Additional `LiveRouteTests`: testIdentityChangeDuringDeviceAndWBIPreparationNeverSendsBusinessRequest,
testIdentityChangeDiscardsInFlightEndpointAndMutationResults,
testEmoteAndReplyContractsKeepBodyOutOfWBIScope, testEndpointUsesTargetScopedDeviceCookie.
`LiveChatClientTests`: testFallbackAndReconnectShareOneFiniteBudget,
testEndpointFailuresAndHostsUseSameBudget, testAuthenticationRefusalAndMalformedAuthNeverFallback,
testRiskControlNeverFallback, testHandshakeDeadlineCancelsUncooperativeReceiver,
testAuthAndMessageInSameFrameAreBothDelivered, testOldTerminationCannotCancelNewGeneration,
testIdentityChangeBeforeConnectionDoesNotCreateSocket,
testIdentityChangeDuringAuthorizationRejectsLateAuthReply,
testReconnectDuplicateBroadcastsAreReducedOnce, testBudgetZeroAndEmptyHostsDoNotCrash.

The App loop is compile-checked only; no App launch, screenshot, real account login, socket
connection or mutation was performed. Unit 2 owns SC HTTP/WebSocket merge/deletion tombstones,
write success receipts and paid-gift state machines; Unit 3 owns full rich chat/activity UI.

Review corrections: `LiveChatSession` now publishes the initial identity before validation and
recaptures a stale snapshot without waiting for another identity event. Retired generations stop
rather than recapturing. Endpoint retry orchestration also lives in Core: it checks the remaining
budget before every endpoint request, consumes each failed preparation once, and stops immediately
when the sixth attempt is consumed. HTTP 401/403 are terminal authentication errors for HTTP
endpoint preparation as well as WebSocket transport.

Additional `LiveChatClientTests`:
`testInitialIdentityCaptureRecoversWithoutAnotherIdentityEvent`,
`testInitialIdentityCaptureCannotRestartRetiredGeneration`,
`testEndpointOrchestrationStopsAfterExactlySixFailures`,
`testEndpointAndSocketOrchestrationShareActualAttemptLimit`,
`testHTTPAuthenticationStopsEndpointOrchestrationAfterOneCall`.

## Unit 2 interaction boundary

`LiveInteractionSession` owns the captured `LiveInteractionContext` (identity epoch/revision,
accountMid, real room ID, anchor ID and room generation), six independent action slots and
cancellable request tasks. Rebinding cancels old tasks; only an operation's UUID can retire
its slot. `read` also carries the context and cancels with the room. App following continues
through `BiliService.setFollowing` and requires App authorization.

Gift quotes are issued by Core, expire after at most 60 seconds, and have unique versions.
The confirmation binds the complete quote and can only be issued once for that quote.
Changing the selection or payment policy invalidates it. A cancelled confirmation is revoked
even during request preparation. The prepared HTTP request remains internal to Core. At the
handoff to the send closure, the session consumes the confirmation synchronously and records
the transaction in the process-wide pending store. In-flight entries stay internal; public pending records expose only unknown transactions,
and manual acknowledgement cannot remove an in-flight entry from any session. Only a verified
HTTP receipt or an explicit nonzero business rejection resolves an in-flight record. Timeout, cancellation, parse failure and code 0
without receipt evidence remain unknown. A late response cannot resolve an invalidated session.
`acknowledgeGiftChecked` is an explicit manual acknowledgement, never an automatic retry.

Production `LiveReceiptPolicy` and fixed gold-price whitelist are empty. Neither code 0 nor
`gift_list` proves a purchase succeeded. Tests inject synthetic receipt evidence. Activity
receipts have a separate validator that receives the complete activity confirmation. Activity
conditions, free participation, automatic danmaku and automatic-follow behavior must all be
known before a confirmation can be issued; no extra danmaku or follow request is generated.

The account limiter reserves a 1.5-second send interval and a 5-second same-content interval
atomically across sessions. Failed attempts are not refunded or queued. Risk codes -352 and
HTTP 412/429 pause manual actions for an injected duration (default 60 seconds). There is no
scheduled resume/send. Super Chat tombstones survive all HTTP/WS merges within a room session;
visibility expires at server `end_time`.

### Unit 2 App wiring and fixture handoff

One `LivePlaybackModel` owns one `LiveInteractionSession`. All live windows subscribe to the
same `LiveInteractionPreferences`; its Mutex-backed `LiveGiftPolicySource` changes synchronously
before UI notification. Quotes also bind a policy revision, including an off/on toggle. The
owner synchronously retires `LiveInteractionLifetime` before asynchronously shutting down the
actor. Bind and shutdown carry lifetime revisions, so an obsolete shutdown cannot clear a new
binding. Live HTTP execution and the existing App-authorized follow pipeline check that lifetime
again immediately before sending. No production mutation gate or receipt validator was opened.

`LiveChatLine`/`LiveChatHistory` retain uid, medal, guard, emotes, reply, identity-bound own-message
status, aggregated gift and Super Chat ID. History is capped at 200 lines and deleted Super Chat
IDs remain tombstoned. `LiveEffectiveSettings` has independent flags; pure mode disables all five
effects but preserves chat text, while hide-gifting removes gift messages and gift effects.

Nine live settings are registered in the existing catalog. Debug `PerformanceEnvironment`
explicitly uses `io.github.pidean.manping.debug`; performance fixtures retain their PID-specific
suite. Unit tests use injected UUID suites. Release defaults were not written.

Run screenshot scenarios outside the sandbox:

```text
--ui-fixture --ui-page live:5000 --ui-live-scene <name>
```

All 14 scenes: `parsing`, `anonymous`, `web-only`, `app-authorized`, `paid-disabled`,
`confirmation-required`, `gift-success`, `rejected`, `timeout`, `late`, `executedResponseLost`,
`risk`, `sc-deleted`, `lottery-unknown`.

New in unit 2: `anonymous`, `web-only`, `app-authorized`, `paid-disabled`,
`confirmation-required`, `gift-success`, `sc-deleted`, `lottery-unknown`.
The six existing scenes now run through the session/contract transport rather than only adding
canned notice text. The late scene waits for the fixture transport to receive a validated POST,
retires the session and discards its late receipt. Its regression test uses continuations,
without wall-clock sleeps. `LiveContractFixture.receiptPolicy` accepts only explicitly marked
synthetic receipts matching the request's gift/activity and bound room/account fields. This
schema is test evidence only, not a claim about Bilibili's real response contract.

`M5LiveFixture` resolves `room_init`, `get_info`, anchor metadata and all unit-2 read samples.
Binary chat fixtures pass through `LiveChatPacket.decode`, including optional Super Chat deletion.
All three identity states use synthetic cookies/device/WBI/token data.

### Unit 2 validation and limitations

Core commit `e7fac21`: build passed; 671 tests, 5 skipped, 0 failures; privacy 0 findings.
App integration commit `946c88a`: build passed; 689 tests, 5 skipped, 0 failures; privacy 0 findings.
The targeted live suites passed 67 tests (32 interaction + 13 integration + 22 existing
route/parsing tests). Formatting commit `87ed681` also passed build, 689 tests (5 skipped, 0 failures), and privacy
0 findings. A subsequent shared-store correction distinguishes in-flight/unknown records and
adds a cross-session premature-acknowledgement/timeout regression; its 46 new tests passed
(33 interaction + 13 integration), with final post-commit checks reported in the handoff.
New Swift files were formatted/linted with `swift-format`; `git diff --check` passed.

App launch, screenshots, real WebSocket connections and real writes were not run. These remain
external validation for Claude. No network contract verification was attempted after the unit-1
risk stop. Production still needs redacted authenticated captures for all mutation routes,
particularly sendGold fixed ordinary-gift pricing, payment receipts, like parameter placement,
activity conditions/automatic side effects and activity success receipts. The current fixed-price
whitelist and receipt policy stay empty in production even when the user enables paid gifts.
Views, effects, payment confirmation UI and activity disclosure UI remain unit 3.

Implementation checks caught and corrected a fixture-test expectation (the default binary frame
contains five events, not more than five); the deletion variant is now explicitly tested. Main
agent integration feedback also added synchronous policy/lifetime sources and a generation-bound
shutdown. No user correction or external-account action was needed. Resource counts alone are
not used as evidence of delivery efficiency.

### Unit 2 added test names (51)
- `LiveInteractionSessionTests.testCharacterAndUTF16Length`
- `LiveInteractionSessionTests.testDanmakuFailureClassification`
- `LiveInteractionSessionTests.testPaidDisabledAtQuoteAndSend`
- `LiveInteractionSessionTests.testThresholdStrictlyGreaterAndRepeatedConfirmation`
- `LiveInteractionSessionTests.testExpiredQuoteAndChangedQuantityInvalidateConfirmation`
- `LiveInteractionSessionTests.testOverflowAndUnsupportedGiftRejected`
- `LiveInteractionSessionTests.testBagCannotTopUpWithGold`
- `LiveInteractionSessionTests.testGiftConfirmationConsumedExactlyOnce`
- `LiveInteractionSessionTests.testConcurrentGiftCallsCannotClearFirstSlot`
- `LiveInteractionSessionTests.testTimeoutAndMalformedBecomeUnknownWithoutReplay`
- `LiveInteractionSessionTests.testCodeZeroWithoutVerifiedReceiptIsUnknown`
- `LiveInteractionSessionTests.testExplicitRejectionResolvesPending`
- `LiveInteractionSessionTests.testRoomSwitchKeepsUnknownAndDiscardsLateSuccess`
- `LiveInteractionSessionTests.testIdentityChangeInvalidatesUnsentTicket`
- `LiveInteractionSessionTests.testCallerCancellationNeverAcceptsLateSuccess`
- `LiveInteractionSessionTests.testRiskPauseOnlyAllowsNewManualActionAfterDeadline`
- `LiveInteractionSessionTests.testSharedAccountRateLimitAndDuplicateContent`
- `LiveInteractionSessionTests.testReplyAndEmoticonDraftFieldsAndLength`
- `LiveInteractionSessionTests.testIndependentActionsAndDuplicateStyleSingleFlight`
- `LiveInteractionSessionTests.testLikesDebounceCountAndIdentityCancellation`
- `LiveInteractionSessionTests.testSuperChatDeletionWinsOverLateHTTPAndExpiryUsesEndTime`
- `LiveInteractionSessionTests.testUnknownLotteryConditionsAndSideEffectsAreRejectedOrDisclosed`
- `LiveInteractionSessionTests.testLotteryDeadlineAndReceiptEvidence`
- `LiveInteractionSessionTests.testPreflightCancellationRevokesTicketWithoutPendingTransaction`
- `LiveInteractionSessionTests.testHTTPRiskAndStyleHexContract`
- `LiveInteractionSessionTests.testLotteryExpiresDuringPreparationWithoutSending`
- `LiveInteractionSessionTests.testSharedPolicySourceDisablesConfirmationSynchronously`
- `LiveInteractionSessionTests.testPolicyChangesDuringPreparationPreventHandoff`
- `LiveInteractionSessionTests.testSynchronousLifetimeRetirementPreventsHandoffAndStaleBind`
- `LiveInteractionSessionTests.testAuthorizedFollowingUsesBoundAnchorAndRiskPause`
- `LiveInteractionSessionTests.testRetiredShutdownCannotClearNewerBinding`
- `LiveInteractionSessionTests.testOtherSessionCannotAcknowledgeInFlightGiftBeforeTimeout`
- `LiveInteractionSessionTests.testWebOnlyFollowingNeedsAppLogin`
- `LiveSessionIntegrationTests.testLiveDefaultsAndEffectiveSettingsAreIndependent`
- `LiveSessionIntegrationTests.testLiveSettingsPersistOnlyInInjectedSuite`
- `LiveSessionIntegrationTests.testRichChatOwnIdentityAndTwoHundredLineLimit`
- `LiveSessionIntegrationTests.testRichGiftAggregationAndDeletedSuperChatNeverReappears`
- `LiveSessionIntegrationTests.testRoomAndAllReadFixturesTraverseServiceDecoders`
- `LiveSessionIntegrationTests.testFixtureThreeIdentityScenes`
- `LiveSessionIntegrationTests.testFixtureGiftSuccessRejectedTimeoutLostAndRiskUseContracts`
- `LiveSessionIntegrationTests.testFixtureDisabledThresholdAndUnknownLotteryDoNotSend`
- `LiveSessionIntegrationTests.testBinaryFixtureFeedsSessionSuperChatTombstones`
- `LiveSessionIntegrationTests.testLateFixtureActuallyExecutesButCannotResolveRetiredSession`
- `LiveSessionIntegrationTests.testPreparedLiveRequestRechecksRetiredLifetimeBeforeTransport`
- `LiveSessionIntegrationTests.testLiveReadRejectsOtherRoomFields`
- `LiveSessionIntegrationTests.testProductionGateStaysClosedEvenWithPaidPreference`

- `LiveSessionBoundaryTests.testLiveTransportTaskRechecksPaidLifetimeIdentityAndCancellationAfterDispatchBarrier`
- `LiveSessionBoundaryTests.testFollowingTransportTaskRechecksLifetimeIdentityAndCancellationAfterDispatchBarrier`
- `LiveSessionBoundaryTests.testReadPublicDeliveryRechecksAnonymousBindingIdentityAndCancellation`
- `LiveSessionBoundaryTests.testFollowingPublicDeliveryRechecksBindingIdentitySlotAndCancellation`
- `LiveSessionBoundaryTests.testAnonymousReadStillSucceedsWithPublicDeliveryChecks`

### Unit 2 independent-review boundary fixes

The full independent review identified two remaining scheduling boundaries. The transport Task
created inside `BiliService.send` now repeats cancellation, captured epoch/revision and the
route's synchronous permission/lifetime hook immediately before invoking `transport.send`.
Both live mutations and App-authorized following pass their hooks through to that Task; other
routes retain a no-op hook. A DEBUG-only internal dispatch barrier lets tests suspend this exact
Task and change paid permission, retire the lifetime, change epoch/revision or cancel the caller.
After the barrier is released, every such test observes zero business requests at the transport.

The public `read` and `setFollowing` methods also revalidate after awaiting their internal Task.
They check the operation slot before and after the outer identity callback, as well as context,
lifetime and caller cancellation. Read preserves anonymous access with `requiresLogin: false`.
The outer-callback tests deterministically rebind, shut down, shut down and rebind the same
context, cancel the caller, or report a changed identity; no retired success is delivered.
These five additional tests passed without wall-clock sleeps. Commit `3a79fa0` passed its full
build/test/privacy checks (690 tests, 5 skipped, 0 failures, privacy 0 findings); the subsequent
review-fix commit's full results are reported by hash in the final handoff. No other scope was
changed for these review fixes.


## Authenticated capture worksheet — empty, not verified

下面只列候选 route；所有采集字段故意留空。既有社区候选契约与单元 1／2 测试证据保留在上文。
只有用户本人手动操作后的脱敏字段名与业务凭据可填入；不保存 Cookie、csrf 值、完整 HAR 或私人消息。

| Route | 采集日期 | Method | URL / path | Query 字段名 | Body 字段名 | CSRF 位置 | 签名输入字段 | Headers | 成功 envelope / receipt | 审核结论 |
|---|---|---|---|---|---|---|---|---|---|---|
| `infoByUser` | | | | | | | | | | |
| `dmConfig` | | | | | | | | | | |
| `emoticons` | | | | | | | | | | |
| `roomGiftList` | | | | | | | | | | |
| `giftConfig` | | | | | | | | | | |
| `bagList` | | | | | | | | | | |
| `superChatList` | | | | | | | | | | |
| `lotteryInfo` | | | | | | | | | | |
| `medalPanel` | | | | | | | | | | |
| `danmuInfo` | | | | | | | | | | |
| `sendDanmaku` | | | | | | | | | | |
| `setDMConfig` | | | | | | | | | | |
| `sendBag` | | | | | | | | | | |
| `sendGold` | | | | | | | | | | |
| `like` | | | | | | | | | | |
| `wearMedal` | | | | | | | | | | |
| `takeOffMedal` | | | | | | | | | | |
| `joinLottery` | | | | | | | | | | |
| `drawRedPocket` | | | | | | | | | | |

### Unit 3 UI handoff

所有场景全集、逐场景命令、主题和窗口参数见 [LiveUIHandoff.md](LiveUIHandoff.md)。
旧 14 个名字仍保留；新增 UI 名字由统一 `LiveSessionFixture.scenes` 校验，未知名称直接拒绝，绝不会落入默认送礼。
场景只使用虚构身份及 `DebugUITransport`。本轮没有启动 App 或截图，不宣称视觉验收通过。
原交易未知结果跨房间显示原 ticket 的 room/anchor/gift/quantity/amount，并且没有重试入口。
