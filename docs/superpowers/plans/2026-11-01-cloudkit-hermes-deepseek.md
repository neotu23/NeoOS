# NeoOS ↔ CloudKit ↔ 本地 Hermes Implementation Plan

> **For agentic workers:** 有技能系统时使用 `superpowers:executing-plans` 逐任务执行；没有技能系统的 DeepSeek 按本文复选框顺序执行，记录证据和阻塞项。执行方式为单执行者顺序实施，不要求启动子代理。

**Goal:** 让 iPhone 上的 NeoOS 通过 CloudKit 向 Mac 本地 Hermes 发送文字、接收执行状态和最终回复，保留已有直接连接。

**Architecture:** 在现有 iOS 应用中增加独立的 CloudKit 异步聊天入口；新增原生 macOS 常驻桥接应用，通过私有 CloudKit 数据库交换请求和结果，再经回环地址连接 `hermes serve`。Hermes 继续拥有会话、模型、工具、记忆及执行权限；CloudKit 只承载消息和状态。

**Tech Stack:** Swift 6、SwiftUI、CloudKit 原生框架、SQLite3、URLSession HTTP/WebSocket、现有 XcodeGen 工程；iOS 17+、macOS 14+。不增加第三方服务端和数据库依赖。

**Spec:** 本文第 2—7 节为随计划交付的设计约定；上游背景见 `docs/ARCHITECTURE.md`、`docs/HERMES_PROTOCOL.md`、`docs/CONNECTING.md`。后续步骤以执行时实际代码为准。

**状态:** 2026-11-01 编写；尚未实现、尚未完成 CloudKit/Hermes 端到端验证。本文中的新文件、接口和测试名均为实施约定，不代表已存在。

## 1. 给 DeepSeek 的执行指令

1. 完整阅读本文，先完成任务 0 的兼容性验证，再开始产品实现。
2. 当前仓库已有大量未提交的改名、中文本地化和其他改动。先查看 `git status --short`、相关文件 diff 和适用的 `AGENTS.md`；不得 reset、覆盖、清理或顺手提交这些改动。
3. 本轮核心交付是第 8 节的文字闭环。第 9 节录音与增强功能是后续阶段，不自动扩展首期范围。
4. 每个任务先补能证明其行为的针对性测试，再实现和运行该测试；配置和纯文案变更用构建/人工检查，无需镜像式测试。
5. 按任务顺序推进，不为普通实现选择反复询问用户。有真实环境阻塞时继续完成独立的代码和测试，把外部步骤单列，不伪称已经联通。
6. 只做相关测试和两端构建，不做全仓库测试、无关重构、发布、部署、Hermes 升级或修改用户已有服务配置。
7. 不自动切换现有连接，不自动把同一条消息从 CloudKit 改投直接连接；模糊投递不能自动重发。
8. 保留 MIT 版权和项目既有声明。新增文件遵循当前项目风格，用户可见名称统一 NeoOS。
9. 除非用户另行要求，不执行 git commit/push。记录建议的任务提交边界即可；暂存时也不能混入现有用户改动。

## 2. 已确认事实、建议决策与范围

### 2.1 代码事实

| 位置 | 当前行为 | 实施含义 |
| --- | --- | --- |
| `HermesIOS/Networking/HermesSocket.swift` | `URLSessionWebSocketTask`、RPC、`client.capabilities`、约 40 秒默认请求超时 | 继续作为直接连接通道，不能原样当 CloudKit 队列 |
| `HermesIOS/Networking/HermesHTTP.swift` | 登录、Keychain 会话、`/api/auth/ws-ticket` | 桥接侧需要本机认证和 fresh ticket，但不能依赖 iOS UI/localizer |
| `HermesIOS/Features/AppModel.swift` | `submit` 要求 `.connected`，建立/恢复会话后调用 `prompt.submit` | 云模式独立建模，不能伪装成 WebSocket 已连接 |
| `HermesIOS/Core/VoiceLiveProtocol.swift` | 当前 `prompt` 构造包含 `session_id`、`text` 等字段 | 未提供持久投递去重保证，不能把 JSON-RPC id 当幂等键 |
| `HermesIOS/Networking/LocalCache.swift` | Application Support 内 JSON 缓存 | 不等于持久任务队列或同步日志 |
| `HermesIOS/Features/RootView.swift` | `connections.isEmpty` 决定是否进入引导 | 只使用 CloudKit、没有直连服务器时也必须能进聊天 |
| `HermesIOS/Features/Chat/ChatComposer.swift` | `ComposerState` 是值类型，但实际 composer 仍绑定 AppModel | 不假设现有 composer 可无改动复用 |
| `HermesIOS/Networking/PushNotifications.swift` | 已有 `NotificationAppDelegate` 和推送分发 | CloudKit 通知必须在现有入口中分流，不能再声明第二个 iOS delegate |
| `HermesIOS/Resources/HermesIOS.entitlements` | 现有 APNs、Keychain 权限，无 CloudKit 权限 | 保留原权限，追加经签名账户确认的容器配置 |
| `Package.swift` | 只将 `HermesIOS/Core` 编译成测试库 | 新共享包要独立测试，不能让旧 Core 目标混进 SwiftUI/CloudKit |
| `project.yml` | XcodeGen 源配置；包含 WebRTC 和多个 iOS extension | 修改生成文件前必须同步源配置并保护现有手工改动 |

本机 `hermes` 启动器在审查时指向 `/Users/neil/.hermes/hermes-agent`，该源码 checkout 的 `git describe` 为 `v0.22.2+canary.20261019T071120Z-1312-gbf0203a794`。这是源码标记，不能当作已运行服务的版本证据。NeoOS README 的验证基线为 Hermes 0.21.7；执行时需要重新核对。

### 2.2 本计划采用的建议决策

- 保留直接连接；新增 CloudKit 异步模式。仅做单 iCloud 用户、单个选定 Mac、默认 Hermes profile 的文字对话。
- 首期有云模式会话列表、新建对话、文字发送、最终回复、失败/不确定状态、Mac 最后联络时间。
- 首期不跨通道接管已有直连会话，不导入全部 Hermes 历史、不支持云模式配置管理/群聊/文件浏览/任意 RPC。
- 原有直连功能继续从已有入口使用；云模式只展示已实现能力。
- 首期不传密码、sudo、secret 或 Hermes provider key。审批默认不自动通过；需要交互的任务显示明确状态，提供停止操作，审批能力作为后续扩展。
- “离线发送”指先落盘排队，恢复网络/前台或获得系统执行机会后同步；不承诺锁屏或强制退出后持续上传。
- 默认不自动删除云端会话。移除本机缓存、清空云端、解绑 Mac 是不同操作；首期只实现退出模式/解绑，不做批量云端删除。

### 2.3 为什么采用这条路线

| 方案 | 取舍 |
| --- | --- |
| 保留直接连接 + 原生 Mac CloudKit 桥接（采用） | iPhone 无需访问 Mac 端口；可复用 Hermes；增加一个常驻 Mac 进程 |
| 仅使用现有直接连接 | 改动少、适合实时语音，但仍需手机到 Mac 的网络路径 |
| Python 直接用 CloudKit server-to-server key | 不能凭这类密钥读取用户私有数据库；额外用户授权/令牌维护偏离首期目标 |

## 3. Global Constraints

- iOS 17+、macOS 14+、Swift 6；按实际安装的 Xcode/SDK 验证 API，不照抄未来版本接口。
- 同一开发者 Team 下配置有权访问的同一 CloudKit 容器；两端同一 iCloud 用户、同一 development/production 环境。不得把 bundle ID、Team ID、容器名写成未经确认的真实值。
- 原有 APNs、Keychain access groups、Widgets、Notification Service、中文/英文/法语本地化和 WebRTC 依赖不得被生成步骤覆盖。
- 新增 Swift macOS 应用目标 `NeoOSBridge`；属于当前仓库，全部新代码与文档也在当前仓库。
- 桥接应用在登录用户的 macOS 会话中运行；首期用户手动启动。不使用 root LaunchDaemon，不自动注册登录启动，不默认阻止系统睡眠。
- 本机 Hermes 凭据存 Mac Keychain，只通过回环 HTTP/WebSocket 调用；不上传 CloudKit，不写日志，不读取/输出 `.env` 内容。
- CloudKit 为私有数据库、自定义 zone；首期只选择一种同步实现：显式 CloudKit operations + 持久增量 token。不同时接入 CKSyncEngine/SwiftData/Core Data 自动云同步。
- 外部签名、容器授权、Schema 部署需实际验证。能力未配置时提供可理解错误，不能静默回退到公共数据库。
- CloudKit ACK 表示“已上传”；Hermes acceptance 表示“已接收执行”；最终结果表示“已完成”。三个概念必须区分。
- 中文优先可用，同时遵循现有 `L(...)` 源语言键与 `.strings` 机制补齐三语。不要直接全局替换原本的法语键。

## 4. 组件、目录与接口

### 4.1 文件职责

新增本地 Swift package `Packages/NeoCloudBridge`，输出三个 library products：

| 目录/文件 | 职责 |
| --- | --- |
| `Packages/NeoCloudBridge/Package.swift` | iOS/macOS 平台及三个 products；无第三方依赖 |
| `Sources/CloudBridgeCore/CloudModels.swift` | Codable/Sendable 领域类型、状态、尺寸上限 |
| `Sources/CloudBridgeCore/MessageReducer.swift` | 去重、状态投影、依赖顺序 |
| `Sources/CloudBridgeCore/BridgeStore.swift` | actor + SQLite3；本地消息、待发送记录、token、执行日志 |
| `Sources/CloudBridgeSync/CloudRecordCodec.swift` | CKRecord 与领域类型转换、版本验证 |
| `Sources/CloudBridgeSync/CloudMailbox.swift` | CloudKit 读写、增量拉取、退避、订阅；统一适配接口 |
| `Sources/HermesBridgeClient/LocalHermesClient.swift` | 本机认证、ticket、RPC、连接能力探测 |
| `Sources/HermesBridgeClient/HermesWireCodec.swift` | 已验证版本的最小协议编解码、类型化结果 |
| `Sources/HermesBridgeClient/HermesKeychain.swift` | 跨 UI 的系统 Keychain 存取，不引用 iOS Localizer |
| `Tests/CloudBridgeCoreTests/` | 状态、落盘、崩溃恢复 |
| `Tests/CloudBridgeSyncTests/` | fake database 故障注入与记录编解码；不依赖真 iCloud |
| `Tests/HermesBridgeClientTests/` | 确认过的协议 fixture、发送前后断线 |
| `NeoOSBridge/NeoOSBridgeApp.swift` | SwiftUI app 生命周期，单实例检测，Mac 通知入口 |
| `NeoOSBridge/BridgeController.swift` | 接收、校验、执行调度、恢复和结果 outbox |
| `NeoOSBridge/BridgeSettingsView.swift` | 账号状态、回环 endpoint、登录、profile、开始/暂停桥接 |
| `NeoOSBridge/BridgeRequestsView.swift` | 当前任务、待交互原因、不确定任务和显式停止 |
| `NeoOSBridge/Resources/Info.plist`、`NeoOSBridge.entitlements` | macOS app 元数据、CloudKit/网络权限 |
| `NeoOSBridgeTests/BridgeControllerTests.swift` | 可替换 Hermes/Mailbox/时钟的桥接控制器测试 |
| `HermesIOS/Features/Cloud/CloudChatModel.swift` | 独立云模式 observable model，不修改 direct runtime 状态 |
| `HermesIOS/Features/Cloud/CloudChatView.swift` | 聊天列表、草稿、发送、状态、同步入口 |
| `HermesIOS/Features/Cloud/CloudConnectionView.swift` | 账号状态、发现/选择 Mac、模式切换 |
| `HermesIOS/Networking/CloudRuntime.swift` | iOS 云同步生命周期和通知入口 |
| `HermesIOS/Core/ConnectionMode.swift` | 本地模式选择，缺字段默认 direct |
| `docs/CLOUDKIT_HERMES_SETUP.md` | 最终真实配置/运行说明 |
| `docs/CLOUDKIT_HERMES_COMPATIBILITY.md` | 任务 0 的服务端版本、接口和恢复能力证据 |

`CloudBridgeCore` 使用系统 SQLite3。任务 1 先验证 SDK 的 `import SQLite3`；若需要 SwiftPM system library，只加一个 `CSQLite` shim 引用系统 `sqlite3.h`，不捆绑 SQLite 二进制。

新增文件按职责拆分，不把整个新功能堆进现有 `AppModel.swift`。现有消息泡和 Markdown 展示可复用；当前 composer 绑定具体 AppModel，首期新增简洁的 Cloud composer，避免为复用而全面重构直连界面。

### 4.2 共享接口约定

以下是职责契约，不要求机械复制示例到无法编译的并发隔离模型中；Swift 6 的 Sendable/actor 细节需在任务 1 编译验证后固定，并在全项目统一。

```swift
public struct AccountScope: Hashable, Codable, Sendable {
    public let containerID: String
    public let environment: String
    public let userRecordName: String
}

public protocol MailboxTransport: Sendable {
    func accountScope() async throws -> AccountScope
    func synchronize() async throws -> SyncSummary
    func publish(_ record: OutboundRecord) async throws -> PublishReceipt
}

public protocol HermesExecuting: Sendable {
    func probe() async throws -> HermesCapabilities
    func resolveConversation(_ conversation: BridgeConversation) async throws -> HermesSession
    func submit(_ request: BridgeRequest, in session: HermesSession) async throws -> Admission
    func recover(_ execution: ExecutionJournal) async throws -> RecoveryOutcome
    func interrupt(_ execution: ExecutionJournal) async throws
    func events() async -> AsyncStream<HermesBridgeEvent>
}
```

所有类型放在其对应 product 中并声明必要的 public 访问；`BridgeStore` 是注入的持久 store，CloudMailbox 和执行控制器不得各建一份分裂的消息数据库。`SyncSummary` 至少包含 saved/received/failed 数量；`PublishReceipt` 表示 CloudKit 已确认的 recordID。`RecoveryOutcome` 为 confirmed/pending/completed/rejected/unknown，不用 Bool 丢弃不确定性。

## 5. CloudKit 数据与投递协议

### 5.1 容器与记录

- 容器从配置读取；示例占位符 `iCloud.<your-team-domain>.NeoOS` 不得直接视为已授权容器。
- 私有数据库中固定 custom zone `NeoOSMailboxV1`。zone 只在初次配置时创建，已有 zone 被删除后进入恢复提示，不能悄悄重建并重放旧任务。
- 每条记录包含 `schemaVersion = 1`，未知版本记录只保存诊断信息并隔离，不执行。
- recordName 由带类型前缀的 UUID 组成，不包含用户文字、路径或凭据。

| Record type | recordName | 关键字段 | 写入方 |
| --- | --- | --- | --- |
| `BridgeDevice` | `bridge_<bridgeID>` | bridgeID、name、protocolVersion、capabilities、lastSeenAt、profileID | Mac |
| `BridgeConversation` | `conversation_<conversationID>` | conversationID、bridgeID、profileID、sourceDeviceID、title、createdAt | 创建它的 iPhone |
| `BridgeRequest` | `request_<messageID>` | messageID、conversationID、bridgeID、profileID、sourceDeviceID、kind、text、previousMessageID?、createdAt | iPhone；提交后不可修改 |
| `BridgeExecution` | `execution_<messageID>` | messageID、bridgeID、state、revision、updatedAt、hermesStoredSessionID?、errorCode?、errorSummary? | 被选中的 Mac |
| `BridgeResult` | `result_<messageID>` | messageID、conversationID、bridgeID、role=assistant、text?、textAsset?、contentSHA256、completedAt、terminalStatus | Mac；最终结果不可修改 |
| `BridgeControl` | `control_<controlID>` | controlID、messageID、bridgeID、kind=cancel、createdAt | iPhone；首期只提供 best-effort 停止 |

本地 `BridgeConversation` 到 Hermes 的 stored/runtime session 映射保存在 Mac 执行日志。先持久化映射再执行，重连时重新 resume，不能把过期 runtime ID 永久当会话主键。

安全校验：bridgeID、profileID、conversationID 必须相互匹配；请求只接受已实现的 kind、固定字段和有效 UUID；不得将云端字符串当任意 RPC 方法、Shell 命令或本地文件路径执行。

### 5.2 尺寸与排序

- 文字请求产品上限 32 KiB UTF-8；空白文字拒绝，超限提示，不静默截断。此为产品决策，不是 Apple 的配额。
- 最终回复 ≤128 KiB UTF-8 时用 text；更大时用 UTF-8 `CKAsset`，首期应用上限 5 MiB。超过上限明确失败/结果过大，不展示截断内容冒充完整结果。
- `text` 与 `textAsset` 恰好一个有值；asset 下载后复制进受控 Application Support，保存成功前不能删除 staging 文件。
- result 的 contentSHA256 对完整 UTF-8 内容计算，用于附件完整性和同 recordName 重试比较；不是 Hermes 是否执行过的判断依据。
- 同一 conversation 连续请求用 `previousMessageID` 建立顺序；首条 nil。前一条已完成后才执行下一条。依赖不存在/未终结时保留等待；前一条失败/取消/不确定后，后续暂停并提示新建对话，不越过前项自动执行。
- 多设备在同一 previousMessageID 上产生分叉时，首期返回 `conversationConflict`，不靠设备时间猜顺序。conversation 首期固定由创建它的 sourceDeviceID 写入；另一个 iPhone 只能阅读或另建对话。
- CloudKit 可能先同步到 result、后同步到 request；先存孤立结果，再关联，不能丢弃或执行一个 result。

### 5.3 本地与云端状态

| 状态 | 定义 | 处理 |
| --- | --- | --- |
| `queuedLocal` | iPhone 已落盘，尚未确认上传 | 自动重试上传同一个 recordName |
| `uploaded` | CloudKit 已确认请求，未确认 Mac 接收 | 展示“等待 Mac”，不代表执行 |
| `received` | Mac 事务落盘，尚未调用 Hermes | 可安全安排首次提交 |
| `dispatching` | Mac 已记“即将调用”；接收结果可能未知 | 重启先恢复，不直接重投 |
| `accepted` / `running` | Hermes 已确认接收/开始 | 等待事件，重连恢复 |
| `waitingOnMac` | 审批/澄清/凭据请求需要人工处理 | 展示原因；不自动同意，不同步秘密 |
| `completed` | 最终结果已在 Mac 持久化 | Mac 可重试上传结果，不能重跑任务 |
| `failed` / `cancelled` | 有明确拒绝/失败/停止证据 | 终结，展示原因 |
| `uncertain` | 可能已提交执行，无法证明结果 | 禁止自动重投；允许查看/重新核对 |

`queuedLocal/uploaded` 为 iPhone 本地投影，不由 Mac 回写覆盖。Mac 写 `BridgeExecution` 的 state/revision，revision 单调递增；不能因旧通知从 completed 降回 running。结果与状态不同步时，以有效最终结果为终结证据；后续补拉收敛。

### 5.4 去重与崩溃窗口

1. iPhone 发送时先在一个本地事务中保存 messageID、内容、draft 清空和 outbox；事务失败则保留草稿且不上传。
2. Mac 增量接收时先保存 request + 初始 journal；`messageID` 为唯一键；重复同步不得新增执行。
3. 调用 Hermes 前把 journal 提交为 `dispatching`，再发网络请求，收到 acceptance 再提交 `accepted`。
4. 新 Hermes 若支持经验证的持久 `input_id`/admission ID 和状态查询，使用 messageID 做输入身份，在同一会话核对后恢复。
5. 旧版本或能力未知时，断线和重启后的 dispatching 转 uncertain。不得用相同文字在历史中出现作为已经执行的充分证据。
6. 最终回答与 result outbox 在同一个 Mac SQLite 事务中持久化。CloudKit 上传失败只重试同一 result 记录，不能重新请求 Hermes。
7. 不承诺端到端 exactly-once。唯一 ID 和本地日志只能去重；无法确认 Hermes acceptance 的窗口必须保留 uncertain，不能用租约超时、进程重启或“再试一次”掩盖。
8. 不自动跨 Mac 故障转移。单实例锁按 macOS 用户 + bridgeID；相同 bridgeID 的第二个进程不能启动 executor。恢复/迁移一台 Mac 不复制并同时启用同一 bridgeID。

### 5.5 同步与账号隔离

- 每次同步通过已知 zone 的 `CKFetchRecordZoneChangesOperation` 拉增量，完整处理 `moreComing` 和删除项。
- 收到一个增量页后，记录数据和新的 token 在本地同一事务提交；持久化失败不得推进 token。
- token 过期时清除该 scope 的 token 并重新全量拉取；重放仍经 messageID 唯一键和 journal，不重跑已完成或 uncertain 的任务。
- 维护 `CKRecordZoneSubscription`；通知只触发补拉，不把通知正文当任务。
- app 启动、回到前台、手动刷新、网络恢复时补拉；Mac 正在桥接时每 30 秒补拉兜底。循环合并并发刷新，不叠加拉取。
- Mac bridge heartbeat 最多每 60 秒一次；超过 180 秒展示“Mac 最近未联络”，仅是活跃提示，不能据此判定任务失败或转交别的 Mac。
- 网络/服务临时错误指数退避并加 jitter：2、4、8…最高 60 秒；Apple retryAfter 更长时必须遵从。账号不可用、权限/Schema 错误停止热重试并显示原因。
- 所有数据库、outbox、token、bridge discovery 和缓存按 `AccountScope` 隔离。账号退出/切换后取消旧任务、隔离旧数据，旧请求绝不上传到新账号；进行中的 Hermes 任务可在原 scope 日志里完成，但结果不能写入新 scope。
- 监听系统 CloudKit 账号变化通知，变化后重新核对用户身份；每个上传周期开始前校验 scope，并给在途回调加账号代次检查，防止旧异步回调写入新账号。账号状态检查失败时暂停上传，不能假设缓存身份仍有效。
- userRecordName 只作内部命名空间，不写普通日志。首次离线无可验证 scope 时只保存草稿，不能把其悄悄归属之后登录的账号。

## 6. 本机 Hermes 对接边界

- endpoint 首期只接受 `localhost`、`127.0.0.1`、`::1`，端口用户配置；外部地址明确拒绝，不自动使用 Tailscale/公网 endpoint。
- 适配器只实现验证过的建/续会话、提交、接收事件、恢复、停止和交互拒绝方法。不能在未验证时硬编码某个 canary 的全部接口。
- 接入前核对正在运行的服务身份/能力、请求格式、回复格式和错误语义；源码里有方法不等于运行服务支持该方法。
- 初期允许默认 profile 的多会话，但 Mac 全局一次执行一条任务；同一会话严格串行。
- 首期 `waitingOnMac` 的可用动作是“停止本次任务”与查看待交互原因，不声称可切去另一个客户端完成原请求。桥接连接必须按协议保有交互请求，直到拒绝/取消/超时；超时按真实服务结果终结。
- UI 中说明“此通道首期不支持审批/补充回答，请使用直接连接发起需要交互的任务”。执行权限沿用 Hermes 原配置，不打开 yolo、不放宽审批规则。
- Hermes 服务未运行/认证失败发生在明确未发送前，任务留在 received 或明确 blocked，显示“等待本机 Hermes”，允许网络级恢复；发送后未知必须 uncertain。

## 7. Review Focus

以下五类必须在所属任务里有行为测试或真实验收证据：

1. Hermes 已执行但回执丢失：任务 0、4、6；恢复不能重复执行。
2. Mac 写入结果但云端上传失败/应用崩溃：任务 2、3、6；恢复只补传同一结果。
3. 两端切换 iCloud 账号、环境或容器：任务 3、5、7；旧数据不串到新 scope。
4. 用户只有云连接、没保存直连 endpoint：任务 7；不会被 RootView 或 composer 挡住。
5. 推送丢失、token 过期、乱序记录：任务 2、3、8；补拉后收敛，终态不回退。

## 8. 首期文字闭环执行任务

### Task 0：验证本机 Hermes 契约，先消除协议风险

**Files:** 新建 `docs/CLOUDKIT_HERMES_COMPATIBILITY.md`；新增 `Packages/NeoCloudBridge/Tests/HermesBridgeClientTests/Fixtures/` 下的脱敏协议 fixture（包结构在任务 1 创建时接入）。

**Interfaces:** 产出可验证的 `HermesCapabilities` 字段表：protocol variant、session identity、durable input identity、admission lookup、event recovery、interactive request、interrupt。

- [ ] 检查服务是否已运行及其监听地址；只看必要的进程/端口信息，不读取或输出凭据。没有服务时记录需要的启动动作，先可用源码和现有 fixture 研究，禁止伪造真机通过证据。
- [ ] 阅读 NeoOS 当前调用路径及实际 Hermes 契约；若需要临时服务，使用独立测试 profile/HERMES_HOME 和空闲回环端口，不改变已有进程。
- [ ] 仅在受控测试会话验证：认证、capability negotiation、建/续会话、提交一条“只回复 OK、不调用工具”的消息、最终事件、停止与断线恢复。
- [ ] 核对持久 input ID 和接收状态查询的实际支持；如无，明确采用 uncertain 降级，不把它当实施阻塞。
- [ ] 记录服务实际版本/commit（可得时）、方法名、必要字段、stored/runtime ID 区别、错误码、一次真实应答证据；fixture 删除 cookie/token/ticket/绝对私人路径。

**完成条件:** 协议表清晰区分“源码发现”“fixture 验证”“真实服务验证”；后续适配器有依据，不写未经核对的请求字段。

### Task 1：建立共享包和跨平台数据契约

**Files:** `Packages/NeoCloudBridge/Package.swift`、`Sources/CloudBridgeCore/CloudModels.swift`、`Sources/CloudBridgeCore/MessageReducer.swift`；测试 `Tests/CloudBridgeCoreTests/CloudModelsTests.swift`、`MessageReducerTests.swift`。

**Interfaces:** public Codable/Sendable 类型至少包括本计划记录对应 DTO，以及 `ExecutionJournal`、`OutboundRecord`、`SyncSummary`、`PublishReceipt`、`HermesCapabilities`、`HermesSession`、`Admission`、`RecoveryOutcome`、`HermesBridgeEvent`。状态及上限精确使用第 5 节。

- [ ] 创建最小包结构并验证系统 SQLite3 导入、Swift 6 actor/Sendable 编译。暂不改现有根包。
- [ ] 写 `testRequestRoundTripPreservesIDs`、`testRejectsBlankAndOversizedText`、`testCompletedCannotRegressToRunning`、`testUnknownSchemaIsQuarantined`。
- [ ] 运行 `swift test --package-path Packages/NeoCloudBridge --filter CloudBridgeCoreTests`，先确认目标测试因未实现行为而失败，再实现模型和纯 reducer。
- [ ] 测 32 KiB UTF-8 边界的中文/emoji；不要用 `String.count` 代替字节数。
- [ ] 再运行同一命令；预期通过，无真实网络或 iCloud 依赖。

### Task 2：实现可恢复的本地消息库

**Files:** `Sources/CloudBridgeCore/BridgeStore.swift`、`Tests/CloudBridgeCoreTests/BridgeStoreTests.swift`。

**Interfaces:** `BridgeStore` 为 actor；提供 `enqueue(_:clearingDraft:)`、`applyRemotePage(_:nextToken:)`、`beginDispatch(messageID:)`、`recordAdmission(messageID:admission:)`、`finish(messageID:result:)`、`pendingOutbound()`、`recoverableExecutions()` 和 scope 隔离的读取接口；写入均 throws。

- [ ] 针对临时 SQLite 数据库写：`testEnqueueAndDraftClearAreAtomic`、`testDuplicateRequestHasSingleJournal`、`testDispatchingSurvivesReopen`、`testResultAndOutboxAreAtomic`、`testTokenDoesNotAdvanceOnFailedCommit`、`testMissingDependencyWaits`、`testAccountScopeIsolatesRows`。
- [ ] 先运行 `swift test --package-path Packages/NeoCloudBridge --filter BridgeStoreTests` 查看预期失败。
- [ ] 使用唯一键、事务和数据库 schemaVersion 实现；数据库位于 app Application Support，不在同步的 iCloud Drive 文件夹中。
- [ ] `beginDispatch` 只接受 received；两次调用第二次必须拒绝。重启后 dispatching 不自动回 received。
- [ ] 将中文草稿保存、事务中断、result 先于 request、账号切换和依赖分叉纳入上述测试，运行通过。

### Task 3：实现 CloudKit 邮箱同步

**Files:** `Sources/CloudBridgeSync/CloudRecordCodec.swift`、`CloudMailbox.swift`；测试 `Tests/CloudBridgeSyncTests/CloudRecordCodecTests.swift`、`CloudMailboxTests.swift`。

**Interfaces:** 实现 `MailboxTransport`；将真实 CloudKit operation 包在可注入 database adapter 后。`synchronize()` 完成分页入库及待发送补传；相同 scope 同时只运行一个 sync cycle。

- [ ] 写 codec 测试：固定 recordName、未知 schema、缺失字段、错误 bridge/profile、超限文字、text/asset 互斥。
- [ ] 写 fake database 测试：`testDuplicatePushCoalescesFetch`、`testFetchConsumesAllPages`、`testExpiredTokenRescanDoesNotRedispatch`、`testUploadAckLostReadsBackSameRecord`、`testAccountSwitchDoesNotUploadOldOutbox`、`testRetryAfterIsRespected`、`testOrphanResultEventuallyLinks`。
- [ ] 运行 `swift test --package-path Packages/NeoCloudBridge --filter CloudBridgeSyncTests` 验证失败后，实现第 5 节的 zone/订阅/分页/token/error/backoff 规则。
- [ ] request/result 创建采用不可变写入；遇到 existing record/serverRecordChanged，重新读取并逐字段验证同一业务内容后才算成功，冲突不能直接覆盖。
- [ ] execution/device 仅 Mac 自己更新，用 changeTag 检测并发；冲突先拉取并合并 revision，禁止 last-write-wins 覆盖终态。
- [ ] 删除会话/请求的云事件在 Mac 下次派发前阻止新执行；已派发不等于已停止，保留 journal 并标注；result 删除不触发重跑。
- [ ] 运行同组测试通过；CloudKit Console schema/真实账号测试留到任务 5、8，单元测试不得依赖系统账号。

### Task 4：实现最小本机 Hermes 适配器

**Files:** `Sources/HermesBridgeClient/LocalHermesClient.swift`、`HermesWireCodec.swift`、`HermesKeychain.swift`；测试 `Tests/HermesBridgeClientTests/LocalHermesClientTests.swift`、`RecoveryTests.swift`。

**Interfaces:** 实现 `HermesExecuting`，具体方法/参数取任务 0 的协议表；`events()` 产生带 messageID/会话归属的 typed event，不能把未知原始帧直接转交执行器。

- [ ] 写 `testRejectsNonLoopbackEndpoint`、`testRPCIDIsNotDurableInputID`、`testFreshTicketOnReconnect`、`testCapabilitiesUnknownDisablesSafeReplay`。
- [ ] 写恢复测试：明确发送前失败可安全重试；发送后 ack 丢失且无持久查询能力必须 unknown；支持 durable ID 时使用同 ID 查询，不能新建请求。
- [ ] 执行 `swift test --package-path Packages/NeoCloudBridge --filter HermesBridgeClientTests` 验证失败后实现连接、response matching、事件监听和重连。
- [ ] 认证实现参考 HermesHTTP/HermesSocket 的思路，不直接把 iOS Keychain/localizer/UI 源文件编入 Mac target，不复制整个 AppModel。
- [ ] 加上 session scope、连接代次隔离和 pending continuation 取消；审批/澄清/secret 只生成 waiting 事件，secret 明文不进日志/云端。
- [ ] 用脱敏 fixture 验证全部测试通过；真实协议不兼容时给具体错误，保留已完成的 store/sync 工作。

### Task 5：新增并签名构建 macOS 桥接应用

**Files:** 新增 `NeoOSBridge/` 入口、设置页、请求页和资源；修改 `project.yml`、现有 `.xcodeproj` 必要差异；新增两个 app 的 CloudKit 配置说明。

**Interfaces:** `BridgeController` 接收注入 store、mailbox、HermesExecuting、clock；对 SwiftUI 暴露账号/桥接状态、连接错误、active tasks 和 start/pause/interrupt/refresh 操作。

- [ ] 在 `project.yml` 添加本地 package 路径和三个 products、`NeoOSBridge` macOS application target、`NeoOSBridgeTests` 与对应 scheme。iOS app 只依赖 CloudBridgeCore/CloudBridgeSync，不拉入 Mac SwiftUI。
- [ ] 使用用户可用 Team 和专用 bundle ID，为两端 app 添加同一 CloudKit 容器权限；保留原 iOS APNs/Keychain。Mac sandbox 如启用需出站网络权限；真实所需 push entitlement 由 capability/签名生成，不猜 entitlement 名称。
- [ ] 实现用户可见设置：iCloud 是否可用、容器环境、Mac 名称、回环地址/端口、凭据输入、默认 profile、连接探测、开始/暂停；密码保存到 Mac Keychain 后从输入状态清空。
- [ ] 第一次桥接主动注册 bridgeID；重启复用，账号变更重新隔离。并发进程用进程锁，第二个 executor 不运行。
- [ ] 按 NSApplicationDelegate/SDK 支持接收 CloudKit 通知；启动和手动刷新也能工作。关闭窗口仍运行，退出 app 才停止；首期不加 Menu Bar/自动登录启动。
- [ ] 添加 container/schema 实际配置到 setup 文档；开发环境先完成 CloudKit Console schema 建立，生产环境部署作为单独人工步骤。
- [ ] 生成前保存现有工程 diff。只有能重现现有手工改动时才 `xcodegen generate`；否则保留并最小修改 `.pbxproj`，不覆盖改名/本地化配置。
- [ ] `xcodebuild -list -project HermesIOS.xcodeproj` 确认新 scheme；运行 `xcodebuild -project HermesIOS.xcodeproj -scheme NeoOSBridge -destination 'platform=macOS' -derivedDataPath /tmp/NeoOSCloudKitDerivedData build`。仅编译可临时用 `CODE_SIGNING_ALLOWED=NO`，但不能据此宣称 iCloud 可用。

### Task 6：实现 Mac 调度、去重和结果回传

**Files:** `NeoOSBridge/BridgeController.swift`、`BridgeRequestsView.swift`、`NeoOSBridgeTests/BridgeControllerTests.swift`。

**Interfaces:** 使用任务 2 的 store、任务 3 的 mailbox、任务 4 的 HermesExecuting；执行器一次只领取一条满足依赖的 request，先 journal 后网络。

- [ ] 写 `testDuplicateDeliveryCallsSubmitOnce`、`testCrashAfterDispatchNeverBlindlyResubmits`、`testCompletedUploadRetryDoesNotInvokeHermes`、`testPerConversationDependencyOrder`、`testOldAccountCompletionStaysInOldScope`、`testInteractivePromptNeverAutoApproves`。
- [ ] 使用注入的 fake Hermes/Mailbox/clock 在测试中模拟：提交前崩溃、提交后 ack 前断线、accepted 后重启、结果已落盘但 CloudKit 失败。
- [ ] 先运行新 Mac test target 的控制器测试，确认行为失败，再实现 received→dispatching→accepted→running→终态流程与第 5.4 节恢复规则。
- [ ] 审批到达时保持真实 session/request 关联，显示 waitingOnMac 和“首期不支持此交互”；用户停止调用经验证的 interrupt/拒绝方法。没有确认前显示“停止请求中”，不先写 cancelled。
- [ ] `BridgeControl` 按 controlID 去重；未派发任务收到 cancel 时在本地事务中阻止派发并记 cancelled，已派发任务走实际 interrupt。control 先于 request 到达时保留并在 request 入库后生效；补 `testCancelBeforeRequestPreventsDispatch` 和 `testRepeatedCancelDoesNotInterruptNewTurn`，过期控制不能停止同会话的下一条消息。
- [ ] 暂停桥接只禁止新任务派发；已接收执行不中途重投。退出时先 checkpoint，重启从 journal 恢复。
- [ ] 测试 heartbeat 和 30 秒兜底通过 fake clock，不用真实 sleep；取消 App 生命周期任务时不留下并发调度器。
- [ ] 运行 `xcodebuild -project HermesIOS.xcodeproj -scheme NeoOSBridge -destination 'platform=macOS' -derivedDataPath /tmp/NeoOSCloudKitDerivedData -only-testing:NeoOSBridgeTests/BridgeControllerTests test`，预期通过；task 5 应把该 test target 纳入 scheme。

### Task 7：接入 iOS 云模式和异步聊天

**Files:** 新增 `HermesIOS/Features/Cloud/`、`HermesIOS/Networking/CloudRuntime.swift`、`HermesIOS/Core/ConnectionMode.swift`；最小修改 `RootView.swift`、`OnboardingView.swift`、`SettingsView.swift`、`HermesIOSApp.swift`、`PushNotifications.swift`、三语 `.strings`。新增 `HermesIOSTests/ConnectionModeTests.swift` 和针对性 UI 测试 `HermesIOSUITests/CloudChatUITests.swift`。

**Interfaces:** `CloudChatModel` 独立持有 active conversation/draft/messages/sync status，并提供 `enqueueText()`、`refresh()`、`requestCancel(messageID:)`；RootView 按 connectionMode 路由，direct 模式仍使用原 AppModel。

- [ ] 写模式兼容测试：旧设置缺 mode 默认 direct；云模式缺直连 endpoint 仍有效；失去 iCloud 不清空本地草稿。
- [ ] 加引导中的“直接连接 / iCloud 异步连接”选择。云模式读取 bridge discovery，只允许选择兼容协议的 Mac；没有 Mac 时给出运行 NeoOSBridge 的具体提示，不创建虚假在线设备。
- [ ] 云模式显示会话列表、新建对话、聊天泡、草稿、发送按钮和消息状态；通过 transaction 入队后清空草稿。无网络但 scope 已知时可排队；无 scope 时保留草稿并解释。
- [ ] canSend 使用非空、尺寸有效、scope/bridge 已选择等条件，不依赖 `AppModel.state == .connected`；“已上传”不能显示成“Mac 正在执行”。
- [ ] 首期不把 CloudKit 注入 `SavedConnection.endpoint`、不新增假 URL、不改旧连接 JSON 结构。记录已选桥接设备时按 AccountScope 隔离。
- [ ] 在同一个 NotificationAppDelegate 中识别 CloudKit notification 后交给 CloudRuntime；保留 Hermes APNs 原有解密、路由和 completion handler，处理分支都必须正常结束。
- [ ] `.active` 补拉、`.background` checkpoint 并结束有限后台任务；不靠 background audio 维持文字同步，不创建永不退出的后台轮询。
- [ ] 云模式隐藏尚未实现的语音/附件/配置/群聊入口，或给明确不可用说明；设置中可以切回原 direct 模式，切换不搬运/重投队列。
- [ ] UI fixture 用注入 store/mailbox：`testCloudModeWithoutDirectServerCanOpenChat`、`testOfflineEnqueueSurvivesRelaunch`、`testUploadedAndRunningHaveDistinctLabels`；一次 direct fixture 验证原有发消息入口不受影响。
- [ ] 运行 `swift test --filter ConnectionModeTests`；用 `xcrun simctl list devices available` 得到真实 simulator UDID，再运行 iOS 新增 UI 测试及原直连相关测试，禁止写不存在的模拟器型号。

### Task 8：真实闭环、故障验收和交付文档

**Files:** 完成 `docs/CLOUDKIT_HERMES_SETUP.md`、`docs/CLOUDKIT_HERMES_COMPATIBILITY.md`；更新 README 的新增能力与边界；验收记录写 `docs/CLOUDKIT_HERMES_VALIDATION.md`。

- [ ] 按实际签名在 Mac/iPhone 登录同一个 iCloud 用户，两端确认同一 container + environment；真机检查通知，模拟器编译结果不能替代推送/后台验证。
- [ ] 正常闭环：iPhone 发送 `只回复 CLOUDKIT_OK，不调用任何工具`；观察等待 Mac、Mac 接收、Hermes 接收、最终回复；重开两端仍存在同一条请求与回复。
- [ ] 关闭 Mac app 后发送两条同会话文字，再启动；严格按依赖顺序处理，Mac 执行次数与消息数一致。
- [ ] iPhone 飞行模式入队后杀进程并重开；已提交本地的消息仍在，恢复网络后上传同 messageID；未发送草稿仍在。
- [ ] 丢弃一次 Mac acceptance 回执；若实际服务无法可靠查询则 uncertain，日志证据不得出现自动第二次 submit。
- [ ] Mac 得到答案后断网，重启桥接再联网；补传同 result，不重跑；用 fake 注入辅助稳定复现崩溃窗口，标注 fake/真实各自覆盖范围。
- [ ] 禁用通知仍能靠手动刷新/前台补拉恢复；token 过期和 result/request 乱序用 fake 验证，不能只测快乐路径。
- [ ] 账号切换、容器环境不一致、iCloud 不可用、Hermes 未启动、认证失败分别显示准确原因，旧 outbox 不串账号；账号切换真机不便时明确标注未测并保留 fake 证据。
- [ ] 检查 direct 模式能保持原有聊天及语音入口；iOS app/Widget/Notification Service 与 Mac target 均能构建。
- [ ] 最后汇总每项通过/失败/未测，带命令、环境、实际服务版本、时间及不含隐私的证据。不要写“CloudKit 理论可行”冒充“端到端已通过”。

## 9. 后续阶段：首期完成后再实施

### 9.1 录音消息

独立阶段，不与首期合并实现：

- iPhone 录制 m4a，产品限制每条 120 秒、10 MiB；先持久化文件，再以 CKAsset 上传。不要经 JSON base64 存音频，不传 PCM 实时块。
- 扩展 request kind 为 audio，记录 mimeType、duration、byteCount、SHA-256 和 asset；旧桥接能力不支持时禁止发送。
- Mac 下载至受控临时目录，验证尺寸/哈希，再调用任务 0 验证过的本机 STT 接口，得到文字后交 Hermes。增加 `transcribing` 状态，转写失败不提交空文本。
- 原始音频和转写入 journal，崩溃恢复不能重复发送 Hermes。上传/下载/转写各自可安全重试，提交后的歧义仍遵守 uncertain。
- iPhone 端转写是另一项可选能力，需额外 Speech 权限、中文准确性和离线能力验证；现有 LocalSpeech 主要是 TTS，不能拿它当已具备 STT 的证据。
- 返回音频可以后续加 TTS asset，但不承诺电话式连续对话或即时打断。

### 9.2 远程审批与分段结果

- 审批/澄清必须绑定原请求 ID、会话、连接代次和有效期；需要单独 threat/行为审查，不在首期把任意答复写成 RPC。
- 分段输出需稳定片段序号、批量节流、最终快照纠正；不按每个 token 写 CKRecord。
- 多 Mac、故障转移、profile 切换和 direct/cloud 共用会话都需要单独设计所有权与投递协议，不可只加设备选择框。
- 自动整理 NeoTodo/Obsidian 留给 Hermes 已有 skill/tool 执行；首期桥接只传消息，不额外修改这些项目或复制业务逻辑。

## 10. 验证命令模板与外部步骤

### 10.1 针对性测试

```sh
# 每次只选当前任务涉及的 suite
swift test --package-path Packages/NeoCloudBridge --filter CloudBridgeCoreTests
swift test --package-path Packages/NeoCloudBridge --filter CloudBridgeSyncTests
swift test --package-path Packages/NeoCloudBridge --filter HermesBridgeClientTests
swift test --filter ConnectionModeTests

# 先确认真实 scheme 和设备，再填 iOS 目标
xcodebuild -list -project HermesIOS.xcodeproj
xcrun simctl list devices available

# macOS 控制器测试；目标须在新 scheme 内
xcodebuild -project HermesIOS.xcodeproj -scheme NeoOSBridge \
  -destination 'platform=macOS' \
  -derivedDataPath /tmp/NeoOSCloudKitDerivedData \
  -only-testing:NeoOSBridgeTests/BridgeControllerTests test

# 把 SIMULATOR_UDID 替换为上面列出的真实可用值
xcodebuild -project HermesIOS.xcodeproj -scheme HermesIOS \
  -destination 'platform=iOS Simulator,id=SIMULATOR_UDID' \
  -derivedDataPath /tmp/NeoOSCloudKitDerivedData \
  -only-testing:HermesIOSUITests/CloudChatUITests test
```

任务 7 的 UI 测试文件可能需要添加进现有 UITest target；准确 class 名和 fixture 启动参数由该任务固定并写到 setup 文档。未创建测试前运行模板命令不能算验证。

### 10.2 可能需要用户在 Xcode/Developer 页面完成的操作

1. 选择有 CloudKit 权限的 Team，确认 iOS/macOS app identifier 和 provisioning profile。
2. 创建或授权同一个 iCloud 容器，确认 development 数据库的 schema 和 zone。
3. 两端系统登录同一 iCloud 用户并允许应用使用 iCloud。
4. 将来分发 TestFlight/生产版前部署 schema 到 production，重新确认两端环境一致。

执行者先完成能独立完成的代码和 fake 验证，再给出具体缺失项及操作位置。不能为了绕过签名把私有消息放公共数据库或把服务端密钥内置 iOS。

## 11. 首期完成定义与回退

- [ ] 两端可构建；所需签名状态、CloudKit 环境和 Hermes 兼容性有真实记录。
- [ ] 纯云模式无直连 endpoint 时可创建对话、离线排队、联网上传、接收 Mac 最终回复。
- [ ] request/result 去重、断线歧义、崩溃恢复、账号隔离和 token 重放均有针对性证据。
- [ ] 任务需审批时无自动越权、无无限“思考中”；能说明原因并按实际协议请求停止。
- [ ] 没有 WebSocket 连接与云上传状态混淆，没有自动跨通道重投。
- [ ] 原有改名/中文本地化/直连功能保留；不混入无关重构。
- [ ] 已测/未测/阻塞项如实列出；真 iCloud 或真 Hermes 未测时只能交付“实现待联调”，不能宣布完整完成。

回退方式：用户将本地 connectionMode 切回 direct，停止 NeoOSBridge。保留云端记录及本地执行日志用于恢复/核对；回退操作不清空 outbox、不重投 uncertain、不修改 Hermes 全局配置。

## 12. 官方参考与审查依据

- [CloudKit 概览](https://developer.apple.com/documentation/cloudkit)：数据存储与同步能力，不运行 Hermes。
- [启用 CloudKit](https://developer.apple.com/documentation/cloudkit/enabling-cloudkit-in-your-app)：容器、账号与 entitlement。
- [配置 iCloud](https://developer.apple.com/documentation/xcode/configuring-icloud-services)：应用和容器关联、签名能力。
- [CloudKit 数据库通知](https://developer.apple.com/documentation/cloudkit/ckdatabasenotification)：通知可能合并，必须补拉实际变化。
- [CloudKit Web Services 认证](https://developer.apple.com/library/archive/documentation/DataManagement/Conceptual/CloudKitWebServicesReference/SettingUpWebServices.html)：server-to-server key 的公共数据库范围。
- [CKRecord](https://developer.apple.com/documentation/cloudkit/ckrecord) 和 [CKAsset](https://developer.apple.com/documentation/cloudkit/ckasset)：结构化记录与文件附件。本文 32 KiB/128 KiB/5 MiB/10 MiB 为产品上限，不宣称是 Apple 固定服务上限。
- [官方 Hermes 源码](https://github.com/NousResearch/hermes-agent)：实际协议以当前运行版本和任务 0 的验证为准。

## 13. 可直接复制给 DeepSeek 的启动提示词

```text
请在当前 NeoOS 仓库执行：
docs/superpowers/plans/2026-11-01-cloudkit-hermes-deepseek.md

先完整阅读文档，检查当前未提交改动和适用 AGENTS.md，再从 Task 0 顺序执行到 Task 8。
本轮只做文字闭环，后续录音/远程审批等不要提前实现。
保留现有 direct HTTP/WebSocket 模式，新增独立 CloudKit 异步模式及 Swift macOS 桥接 app。
重要：先验证实际本机 Hermes 契约；CloudKit 通知不是可靠任务队列；提交歧义不得自动重跑；账号切换不得混传。
只做相关测试和构建，保护已有改名、本地化和其他未提交改动，不自动 commit/push，不升级或修改现有 Hermes 服务。
签名/容器等外部配置缺失时继续完成可独立部分，交付具体阻塞项。每阶段汇报文件变更、已运行命令、验证结果和下一步。
```
