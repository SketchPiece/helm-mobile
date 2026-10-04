# T3 Code / Helm WebSocket RPC spec for a native SwiftUI client

Scope: the subset of the server WebSocket RPC that `apps/mobile` + `packages/client-runtime` actually use for:
server info, projects, thread list (shell), thread detail, sending messages / starting turns, interrupt,
approvals + user-input requests, thread creation, model catalog, archive/delete, attachments, queue.

Repo: `/Users/you/Documents/Projects/t3code` (branch `helm`). All paths below are relative to it.
Effect version on the wire: `effect@4.0.0-rc.115` (vendored copy at `.repos/effect-smol`, installed copy under
`node_modules/.pnpm/effect@4.0.0-rc.115_*/node_modules/effect/src/unstable/rpc/`).

Key source files:

| What | File |
|---|---|
| RPC method names + `Rpc.make` definitions + `WsRpcGroup` | `packages/contracts/src/rpc.ts` (WS_METHODS :343, group :1697) |
| Orchestration V2 schemas (thread, run, turn items, events, commands, stream items, RPC schemas) | `packages/contracts/src/orchestrationV2.ts` |
| Base ids / helpers | `packages/contracts/src/baseSchemas.ts` |
| Server WS route + handlers | `apps/server/src/ws.ts` (route `/ws` :3748, orchestration handlers :1755-1995, subscribe impls :649 / :841) |
| What the server strips before sending | `apps/server/src/orchestration-v2/WireProjection.ts` |
| Client WS session (socket + JSON serialization) | `packages/client-runtime/src/rpc/session.ts` |
| Command builders (dispatch, launch, interrupt, approvals, queue) | `packages/client-runtime/src/operations/commands.ts` |
| Shell reducer | `packages/client-runtime/src/state/shellReducer.ts`, `state/shell.ts` |
| Thread reducer | `packages/client-runtime/src/state/orchestrationV2Projection.ts`, `state/threads.ts` |
| Turn-item visibility | `packages/shared/src/orchestrationV2Timeline.ts` |
| Pending approvals / questions | `packages/client-runtime/src/state/threadRequests.ts` |
| Queue derivation | `packages/client-runtime/src/state/threadWorkflows.ts` |
| Mobile new-thread payload | `apps/mobile/src/lib/projectThreadStartTurn.ts` |
| Mobile send (outbox) | `apps/mobile/src/state/use-thread-outbox-drain.ts` (:774-920), `state/use-thread-composer-state.ts` (:657-700) |
| Mobile attachment upload | `apps/mobile/src/lib/attachmentUpload.ts`, `packages/client-runtime/src/state/attachments.ts` |
| Mobile timeline presentation | `apps/mobile/src/lib/threadActivity.ts` (`buildThreadFeed` :1633) |

---

## 1. Transport

### 1.1 Connecting

- URL: `ws(s)://<host>/ws?wsTicket=<ticket>&orchestrationProtocol=2[&clientSurface=mobile&clientDeviceType=phone&clientOs=iOS&clientAppVersion=...&connectionMethod=direct]`
  - `orchestrationProtocol=2` is **mandatory**. Without it (or with another value) the server answers HTTP **426**
    `{"code":"orchestration_protocol_incompatible","message":...,"orchestrationProtocolVersion":2}`
    (`apps/server/src/ws.ts:3758-3768`; constant `ORCHESTRATION_PROTOCOL_VERSION = 2`, param name
    `ORCHESTRATION_PROTOCOL_QUERY_PARAM = "orchestrationProtocol"` in `packages/contracts/src/environment.ts:13-15`;
    client appends it in `packages/client-runtime/src/connection/compatibility.ts:38`).
  - Path defaults to `/ws` if the base URL has no path (`packages/client-runtime/src/authorization/remote.ts:201-224`).
  - Optional client metadata params: `clientSurface`, `clientAppVersion`, `clientDeviceType` (`phone|tablet|desktop|unknown`),
    `clientOs` (`iOS`...), `clientOsMajorVersion`, `clientDeviceModel`, `connectionMethod` (`direct|ssh|relay|unknown`)
    (`remote.ts:42-84`).
- `wsTicket`: short-lived ticket from `POST {httpBase}/api/auth/websocket-ticket` with header
  `Authorization: Bearer <accessToken>` (or `DPoP <token>` + `dpop:` header for relay). Response
  `{"ticket": string, "expiresAt": "<ISO>"}` (`packages/contracts/src/auth.ts:207`, endpoint `environmentHttp.ts:459`).
  The server authenticates the upgrade via `serverAuth.authenticateWebSocketUpgrade` (`ws.ts:3772`).
  (Bearer tokens come from `/oauth/token` token exchange of a pairing credential; out of scope here.)

### 1.2 Framing (Effect RPC, JSON serialization)

Client and server both use `RpcSerialization.layerJson` (`session.ts:205`, server `ws.ts:3800`).
One WebSocket text frame = `JSON.stringify(message)` of one message. The JSON parser also accepts a top-level
array of messages (`RpcSerialization.ts:122-133`), so a native decoder should accept either an object or an array.

Every message has a `_tag` discriminator. Encoded envelopes (`RpcMessage.ts:65-470`):

Client -> server:
```jsonc
{"_tag":"Request","id":0,"tag":"orchestration.subscribeShell","payload":{...},"headers":[]}
{"_tag":"Ack","requestId":0}          // REQUIRED after every stream Chunk (see 1.3)
{"_tag":"Interrupt","requestId":0}    // cancel a stream / in-flight request
{"_tag":"Ping"}                       // keepalive; server replies {"_tag":"Pong"}
{"_tag":"Eof"}                        // optional, graceful end
```
- `id`: `string | number`. The Effect client uses an incrementing integer counter starting at 0
  (`RpcClient.ts:211,266`). Any unique string or number is accepted and echoed back as `requestId`.
- `headers`: array of `[string,string]` tuples. Send `[]`.
- Optional `traceId`, `spanId`, `sampled` — omit.

Server -> client:
```jsonc
{"_tag":"Chunk","requestId":0,"values":[ <item>, <item>, ... ]}   // stream items (non-empty batch)
{"_tag":"Exit","requestId":0,"exit":{"_tag":"Success","value": <success>}}
{"_tag":"Exit","requestId":0,"exit":{"_tag":"Failure","cause":[
    {"_tag":"Fail","error": <typed error, has its own "_tag">} |
    {"_tag":"Die","defect": <any JSON>} |
    {"_tag":"Interrupt","fiberId": number|null}
]}}
{"_tag":"Defect","defect": <any JSON>}    // whole-connection failure; fail all in-flight requests
{"_tag":"Pong"}
```
- Unary RPC: exactly one `Exit`.
- Stream RPC (`stream: true`): zero or more `Chunk`s then a terminal `Exit` (`Success` with no meaningful value
  when the stream ends normally; `Failure` on error). Long-lived subscriptions normally never end.

### 1.3 Stream backpressure: you MUST Ack

The server WebSocket protocol has `supportsAck: true` (`RpcServer.ts:1394`, used by
`makeProtocolWithHttpEffectWebsocket`). For each stream request the server writes one `Chunk`, then **waits on a latch
until the client sends `{"_tag":"Ack","requestId":<id>}`** before writing the next chunk
(`RpcServer.ts:395-440`; client side sends Ack right after enqueueing each chunk, `RpcClient.ts:565-575`).
A native client that does not Ack will see exactly one chunk per subscription and then silence.

### 1.4 Keepalive

The Effect client sends `{"_tag":"Ping"}` every 5 s and treats a missing `Pong` by the next tick as a timeout
(`RpcClient.ts:1201-1222`). The server answers every Ping with Pong (`RpcServer.ts:799`). The server does not ping.

### 1.5 Errors common to every RPC

Every RPC's error union includes `EnvironmentAuthorizationError`
(`packages/contracts/src/auth.ts:297`):
```json
{"_tag":"EnvironmentAuthorizationError","message":"...","requiredScope":"orchestration:operate"}
```
`requiredScope` ∈ `orchestration:read | orchestration:operate | terminal:operate | review:write | access:read | access:write | relay:read | relay:write`.
Schema `TaggedError`s encode as `{"_tag": "<ClassName>", ...fields}`. Fields typed `Schema.Defect()` (usually
`cause`) are arbitrary JSON — decode as opaque.

---

## 2. Wire encoding rules (Schema -> JSON)

The JSON serialization runs every payload/success/error through `Schema.toCodecJson` (`RpcSerialization.ts:28-40`).
That gives these rules for the subset:

| Schema | JSON | Swift |
|---|---|---|
| Branded ids (`ThreadId`, `ProjectId`, `CommandId`, `MessageId`, `RunId`, `RunAttemptId`, `NodeId`, `TurnItemId`, `RuntimeRequestId`, `PlanId`, `CheckpointId`, `CheckpointScopeId`, `ProviderThreadId`, `ProviderTurnId`, `ProviderSessionId`, `ContextHandoffId`, `ContextTransferId`, `EventId`, `RawEventId`, `ScheduledTaskId`, `EnvironmentId`) | plain string, trimmed, non-empty (`baseSchemas.ts:126-215`) | `String` (or a `RawRepresentable` newtype). Clients generate ids as **UUID v4 strings** (`apps/mobile/src/lib/commandMetadata.ts:10-24`). |
| `ProviderInstanceId`, `ProviderDriverKind` | string slug `^[a-zA-Z][a-zA-Z0-9_-]*$`, max 64 (`providerInstance.ts:61-83`). Driver examples: `codex`, `claudeAgent`, `cursor`, `grok`, `pi`, `opencode`... | `String` |
| `Schema.DateTimeUtc` | ISO-8601 string produced by JS `Date.toISOString()`: **always** `YYYY-MM-DDTHH:mm:ss.SSSZ` (`Schema.ts:10806-10939`, `DateTime.formatIso`) | Decode with `ISO8601DateFormatter` + `.withFractionalSeconds`; be lenient (decode accepts anything `Date` parses). Encode with ms + `Z`. |
| `Schema.DateTimeUtcFromString` (the `*Json` mirror schemas) | same ISO string | same |
| `IsoDateTime` | **plain `Schema.String`** (no validation) (`baseSchemas.ts:35`). Used for `snoozedUntil`, `visitedAt`, `resetAt`, project `createdAt/updatedAt`, provider `checkedAt`, plan-step `durationAnchorAt`. | `String` (parse as ISO if needed) |
| `TrimmedNonEmptyString` | string; server trims on decode and rejects empty | Send trimmed, non-empty. |
| `NonNegativeInt` / `PositiveInt` / `Schema.Int` | JSON integer | `Int` |
| `Schema.Number` | JSON number (e.g. `expiresAt` epoch-ms on upload URLs) | `Double` |
| `Schema.optional(X)` / `Schema.optionalKey(X)` | key **omitted** when absent | `decodeIfPresent`; never send `null` for these |
| `Schema.NullOr(X)` | key present, value `null` or X | `Optional` but encode explicit `null` when sending |
| `Schema.optional(Schema.NullOr(X))` | absent, `null`, or X | `Optional` |
| `.pipe(Schema.withDecodingDefault(...))` | server may omit; client fills default (e.g. `settledOverride` -> null, `pendingBackgroundTasks` -> `[]`) | `decodeIfPresent ?? default` |
| `Schema.Literals([...])` | string enum | `enum: String, Codable` — **add an `unknown(String)` fallback**: literal sets grow (status, kinds, event types). |
| `Schema.TaggedStruct("x", {...})` / `TaggedError` | object with `"_tag":"x"` | discriminate on `_tag` |
| `Schema.Unknown` / `Schema.Record(String, Unknown)` | arbitrary JSON | a `JSONValue` enum |
| `Schema.Option(X)` (not used in this subset) | `{"_tag":"Some","value":X}` / `{"_tag":"None"}` | |
| `Schema.BigInt` (not used in this subset) | string | |

Discriminators in this API:
- RPC envelopes and errors: `_tag`.
- Orchestration domain events, commands, turn items, `forkedFrom`, `dispatchMode`, `workspaceStrategy`,
  `responseCapability`, attachments: **`type`**.
- Shell / thread stream items, plan artifacts, pending background tasks, notification sources: **`kind`**.

Forward compatibility the TS client relies on (mirror it):
- `ForwardCompatibleArray` (`baseSchemas.ts:116`): drops array elements it cannot decode (used for `providers`,
  `supportedRuntimeModes`, `issues`, `availableEditors`, context records). Decode arrays element-wise and skip failures.
- Thread stream unknown event types decode to `{kind:"unknown-event", sequence, eventType}` and are skipped but still
  advance the cursor (`orchestrationV2.ts:3071-3137`, `threads.ts:443-468`).
- `kindUnionWithFallback` (`orchestrationV2.ts:736`): unknown `kind` on pending background tasks -> `background_task`;
  unknown notification source -> `{kind:"background_task"}`.
- `ChatAttachment` has an unknown-type arm (`ChatUnknownAttachment`): any `type` not `image|file` with base fields.

`ModelSelection` (`packages/contracts/src/modelSelection.ts`): wire shape
```json
{"instanceId":"codex","model":"gpt-5.4","options":[{"id":"effort","value":"high"},{"id":"fastMode","value":true}]}
```
`options` is optional (key omitted). Decoder also accepts legacy `{"provider":"codex",...}` and legacy object options
`{"effort":"high"}`; the server always **encodes** the canonical array form. `value` is `TrimmedNonEmptyString | Boolean`.

---

## 3. RPC catalog (subset used by mobile)

Legend: **S** = stream (`stream: true`), payload = request `payload`, success = `Exit.value` (unary) or each chunk value (stream).

| Area | Tag | Payload | Success | S | Errors (besides EnvironmentAuthorizationError) | Def |
|---|---|---|---|---|---|---|
| Server info | `subscribeServerConfig` | `{environmentThemes?:bool, usageLimitSources?:bool, usageLimitsCommand?:bool}` | `ServerConfigStreamEvent` (first is `snapshot`) | S | `KeybindingsConfigError`, `ServerSettingsError` | rpc.ts:1607 |
| Server info | `server.getConfig` | `{}` | `ServerConfig` | | same | rpc.ts:561 |
| Server info | `server.probe` | `{}` | `{}` | | — | rpc.ts:555 |
| Server info | `subscribeServerLifecycle` | `{}` | `ServerLifecycleStreamEvent` | S | — | rpc.ts:1631 |
| Model catalog | `server.refreshProviders` | `{instanceId?, cwd?, fresh?:bool, refreshModels?:bool}` | `{providers: ServerProvider[]}` | | `ProviderSetupError` | rpc.ts:567 |
| Projects + thread list | `orchestration.subscribeShell` | `{afterSequence?:int, requestCompletionMarker?:bool}` | `OrchestrationV2ShellStreamItem` | S | `OrchestrationV2GetShellSnapshotError` | rpc.ts:1579 |
| Archived threads | `orchestration.getArchivedShellSnapshot` | `{}` | `OrchestrationV2ArchivedShellSnapshot` | | `OrchestrationV2GetShellSnapshotError` | rpc.ts:1536 |
| Archived threads | `orchestration.subscribeArchivedShell` | `{}` | `OrchestrationV2ArchivedShellStreamItem` | S | same | rpc.ts:1569 |
| Thread detail | `orchestration.subscribeThread` | `{threadId, afterSequence?:int, requestCompletionMarker?:bool, acceptBoundedSnapshot?:bool}` | `OrchestrationV2ThreadStreamItem` | S | `OrchestrationV2GetThreadProjectionError` | rpc.ts:1586 |
| Thread detail (one-shot) | `orchestration.getThreadProjection` | `{threadId}` | `OrchestrationV2ThreadProjection` (bounded window) | | same | rpc.ts:1545 |
| All commands | `orchestration.dispatchCommand` | `OrchestrationV2Command` (see §6) | `{sequence:int}` | | `OrchestrationV2DispatchCommandError` | rpc.ts:1509 |
| Create thread + first message | `orchestration.launchThread` | `OrchestrationV2ThreadLaunchInput` | `{threadId, projection: ThreadProjection, resumed:bool}` | | `OrchestrationV2ThreadLaunchError` | rpc.ts:1563 |
| Attachments | `attachments.createUploadUrl` | `{type?:"image", name, mimeType, sizeBytes}` or `{type:"file", name, mimeType, sizeBytes}` | `{attachmentId, relativeUrl, expiresAt:number}` | | `AttachmentUploadSigningKeyError` | rpc.ts:1220 |
| Attachments | `attachments.delete` | `{attachmentId}` | (void) | | — | rpc.ts:1226 |
| Attachments (legacy inline) | `assets.persistChatAttachments` | `{threadId, messageId, attachments: UploadChatImageAttachment[]}` | `{attachments: ChatAttachment[]}` | | `PersistChatAttachmentsError` | rpc.ts:1214 |
| Asset URLs (view attachment, verify upload) | `assets.createUrl` | `{resource: AssetResource}` | `{relativeUrl, expiresAt:number, sourcePath?, imageDimensions?:{width,height}}` | | `AssetAccessError` union | rpc.ts:1208 |
| Scratch project | `projects.ensureScratch` | `{}` | `{projectId}` | | `OrchestrationDispatchCommandError` | rpc.ts:1167 |
| Turn diff (file changes) | `orchestration.getTurnDiff` | `{threadId, fromTurnCount:int, toTurnCount:int, ignoreWhitespace?:bool}` | `{threadId, fromTurnCount, toTurnCount, diff:string}` | | `OrchestrationGetTurnDiffError` | rpc.ts:1515 |
| Voice (Helm) | `voice.transcribe` | `{attachmentId, threadId?, durationSeconds?:number}` | `{text}` | | `VoiceTranscribeError{reason:"unavailable"|"not-found"|"too-large"|"failed"}` | rpc.ts:1231 |

Note: there are no separate RPCs for interrupt, approvals, archive, delete, queue, or mode changes. They are all
`orchestration.dispatchCommand` with different `type`s (§6). Projects are not listed by an RPC either; they come in the
shell snapshot (§4).

Orchestration error shapes (`orchestrationV2.ts:3140-3176`):
```jsonc
{"_tag":"OrchestrationV2DispatchCommandError","commandId":"...","commandType":"message.dispatch","message":"...","detail?":"...","cause?":<json>}
{"_tag":"OrchestrationV2GetThreadProjectionError","threadId":"...","message":"...","cause?":<json>}
{"_tag":"OrchestrationV2GetShellSnapshotError","message":"...","cause?":<json>}
{"_tag":"OrchestrationV2ThreadLaunchError","commandId":"...","projectId":"...","message":"...","cause?":<json>}
```
`dispatchCommand` puts a user-facing reason in `detail`/`message` (`ws.ts:1770-1779`).

### 3.1 Server info / capability negotiation

The TS client opens `subscribeServerConfig` first and takes the first `{"type":"snapshot"}` event as the
initial config (`packages/client-runtime/src/rpc/session.ts:223-299`). It then checks
`config.environment.environmentId` matches the paired environment.

`ServerConfigStreamEvent` (`packages/contracts/src/server.ts:735-805`), all carry `"version":1`:
```jsonc
{"version":1,"type":"snapshot","config": ServerConfig}
{"version":1,"type":"providerStatuses","payload":{"providers":[ServerProvider...]}}   // replace providers
{"version":1,"type":"settingsUpdated","payload":{"settings": ServerSettings}}
{"version":1,"type":"keybindingsUpdated","payload":{"keybindings":...,"issues":[...]}}
{"version":1,"type":"environmentThemesUpdated","payload":{"themes":[...]}}           // only if opted in
{"version":1,"type":"usageLimitSourcesUpdated","payload":{"sources":[...]}}           // only if opted in
```
Do NOT opt in to `environmentThemes`/`usageLimitSources` unless you decode those events.

`ServerConfig` (`server.ts:604`) — fields relevant to a chat client:
```jsonc
{
  "environment": {                       // ExecutionEnvironmentDescriptor, environment.ts:209
    "environmentId": "env-…", "label": "MacBook", "serverVersion": "…",
    "orchestrationProtocolVersion": 2,   // optionalKey
    "platform": {"os":"darwin|linux|windows|unknown","arch":"arm64|x64|other","machine?":"laptop|…"},
    "capabilities": { …see below… }
  },
  "auth": {...}, "cwd": "/…", "keybindingsConfigPath": "…", "keybindings": [...], "issues": [...],
  "providers": [ServerProvider, ...],    // model catalog
  "availableEditors": [...], "observability": {...},
  "settings": ServerSettings,            // large; decode leniently. Has defaultModelSelection (NullOr ModelSelection) and defaultRuntimeMode
  "shellResumeCompletionMarker?": true,  // server can emit {"kind":"synchronized"} on shell subscriptions
  "threadResumeCompletionMarker?": true, // same for thread subscriptions
  "scratchWorkspaceRoot?": "…", "newProjectsRoot?": "…"
}
```
`ExecutionEnvironmentCapabilities` flags that change client behavior (`environment.ts:95-205`, all optional booleans
unless noted): `attachmentUploads` (use `attachments.createUploadUrl`; else inline `dataUrl`), `fileAttachments`
(`{maxUploadBytes:int}`; else images only), `questionAttachments`, `inlineMessageContext`,
`serverResolvedCommandContext` (server resolves dispatch mode/model-selection; simplifies §6), `threadSettlement`,
`threadSnooze`, `threadPinning`, `threadPinReorder`, `threadActiveReorder`, `threadVisitedTracking`,
`threadTitleRegeneration`, `threadAutoSettleOptOut`, `voiceTranscription` (Helm), `connectionProbe`,
`requiredWorktreeBootstrap`, `repositoryIdentity` (bool, default false), `serverSelfUpdate` (enum)...

### 3.2 Model / provider catalog

`ServerProvider` (`server.ts:211-286`):
```jsonc
{
  "instanceId": "codex",                 // routing key -> ModelSelection.instanceId
  "driver": "codex",                     // codex | claudeAgent | cursor | grok | opencode | pi | ...
  "displayName?": "Codex", "accentColor?": "...", "iconUrl?": "...", "badgeLabel?": "...",
  "showInteractionModeToggle?": true,    // plan mode toggle
  "reportsContextWindow?": true,
  "supportedRuntimeModes?": ["approval-required","auto-accept-edits","auto","full-access"],
  "requiresNewThreadForModelChange?": false,
  "supportsConversationRollback?": true, "supportsTextGeneration?": true,
  "enabled": true, "installed": true, "version": "0.50.0" | null,
  "status": "ready" | "warning" | "error" | "disabled",
  "auth": {"status":"authenticated|unauthenticated|unknown","type?":"…","label?":"…","email?":"…"},
  "checkedAt": "<ISO string>", "message?": "…",
  "availability?": "available" | "unavailable",   // absent == available
  "unavailableReason?": "…",
  "models": [ServerProviderModel, ...],
  "slashCommands": [{"name":"…","description?":"…","input?":{"hint":"…"}}],   // default []
  "skills": [...],                                                            // default []
  "usageLimits?": {...}, "versionAdvisory?": {...}, "compatibilityAdvisory?": {...}, "updateState?": {...}
}
```
`ServerProviderModel` (`server.ts:75`):
```jsonc
{"slug":"gpt-5.4","name":"GPT-5.4","shortName?":"…","subProvider?":"…","aliases?":["…"],"badge?":"new",
 "isCustom":false,"isDefault?":true,"isLegacy?":false,
 "capabilities": null | {"optionDescriptors?":[ProviderOptionDescriptor...]}}
```
`ProviderOptionDescriptor` (`model.ts:18-43`), discriminated by `type`:
```jsonc
{"id":"effort","label":"Reasoning","description?":"…","type":"select",
 "options":[{"id":"high","label":"High","description?":"…","isDefault?":true}],
 "currentValue?":"high","promptInjectedValues?":["…"]}
{"id":"fastMode","label":"Fast","description?":"…","type":"boolean","currentValue?":true}
```
Building a `ModelSelection` from the catalog: `{instanceId: provider.instanceId, model: model.slug, options?: [{id, value}]}`
where each option id is a descriptor `id` and value is a select choice `id` or a boolean
(mobile: `apps/mobile/src/lib/modelOptions.ts`, `normalizeSelectionOptions`).
Usable providers: `enabled && installed && availability != "unavailable"` and status not `disabled`.
The mobile also blocks unavailable Antigravity selections (`isModelSelectionUnavailable`).

`RuntimeMode` = `"approval-required" | "auto-accept-edits" | "auto" | "full-access"` (default `full-access`).
`ProviderInteractionMode` = `"default" | "plan"` (`providerPolicy.ts:24-36`).

---

## 4. Shell read model (projects + thread list)

### 4.1 Subscribe

`orchestration.subscribeShell` payload:
```json
{"requestCompletionMarker": true}
```
(add `"afterSequence": <n>` only when you hold a cached snapshot with that `snapshotSequence`.)
Send `requestCompletionMarker` only if `ServerConfig.shellResumeCompletionMarker === true`
(`packages/client-runtime/src/state/shell.ts:226-292`). The TS client loads the initial snapshot over HTTP
(`GET {httpBase}/api/orchestration/shell`, `state/shellSnapshotHttp.ts:46`) and then resumes the socket with
`afterSequence`; a native client can skip HTTP and just subscribe without `afterSequence` to get a socket snapshot.

Server emission order (`ws.ts:841-1073`):
1. No `afterSequence`: one authoritative `snapshot` frame (projects + active threads, `archivedThreads: []`), optionally
   followed by a same-sequence *enrichment* `snapshot` (see below), then `{"kind":"synchronized"}` (if requested), then live deltas.
2. With `afterSequence` and a small gap: an enrichment `snapshot` (projects metadata only, `threads: []`), replayed deltas,
   `synchronized`, live deltas. Large gap (> 1000 events): falls back to (1).

### 4.2 Stream items (`OrchestrationV2ShellStreamItem`, `orchestrationV2.ts:1786-1822`), discriminator `kind`

```jsonc
{"kind":"synchronized"}
{"kind":"snapshot","snapshot": ShellSnapshot, "resolvedRepositoryIdentityRoots?": ["/abs/root", ...]}
{"kind":"project.updated","sequence":123,"project": OrchestrationProjectShell}
{"kind":"project.removed","sequence":124,"projectId":"…"}
{"kind":"thread.updated","sequence":125,"location":"active"|"archive","thread": ThreadShell}
{"kind":"thread.removed","sequence":126,"location":"active"|"archive","threadId":"…"}
```

**Critical:** a `snapshot` whose item has `resolvedRepositoryIdentityRoots` present is a metadata-only *enrichment*
frame. Its `threads` are `[]`. Do not replace your thread list with it; only patch `project.repositoryIdentity` for matching
projects (`shellReducer.ts:50-94`, `mergeShellSnapshotProjects`). Only a snapshot without that key is authoritative.

`ShellSnapshot` (`orchestrationV2.ts:1772-1784`):
```jsonc
{"schemaVersion":1,"snapshotSequence":4211,"projects":[OrchestrationProjectShell...],
 "threads":[ThreadShell...],"archivedThreads":[ThreadShell...]}
```

`OrchestrationProjectShell` (`packages/contracts/src/orchestrationProject.ts:9`):
```jsonc
{
  "id":"0b2f…","title":"t3code","workspaceRoot":"/Users/me/Projects/t3code",
  "repositoryIdentity?": null | {"canonicalKey":"github.com/x/y","locator":{"source":"git-remote","remoteName":"origin","remoteUrl":"…"},
                                 "webUrl?":"…","rootPath?":"…","displayName?":"…","provider?":"github","owner?":"x","name?":"y"},
  "defaultModelSelection": null | ModelSelection,
  "defaultThreadEnvMode?": null | "local" | "worktree",
  "autoPull?": false,
  "faviconPath?": null | "public/favicon.svg",
  "projectIcon?": null | {"kind":"lucide","name":"folder-code","color":"blue","monogramText?":"…"} | {"kind":"emoji",...} | {"kind":"monogram",...},
  "scripts":[{"id":"…","name":"Dev","command":"vp run dev","icon":"play|test|lint|configure|build|debug","runOnWorktreeCreate":false,"async?":true,"previewUrl?":"…","autoOpenPreview?":false}],
  "createdAt":"<ISO string>","updatedAt":"<ISO string>"      // IsoDateTime (plain strings)
}
```

`OrchestrationV2ThreadShell` (`orchestrationV2.ts:1684-1769`) — one row in the thread list:
```jsonc
{
  "createdBy":"user"|"agent"|"system",
  "creationSource":"web"|"mobile"|"mcp"|"provider"|"server",
  "id":"8c1e…","projectId":"0b2f…",
  "title":"Fix login bug",                       // plain String here (may be empty)
  "providerInstanceId":"codex",
  "modelSelection":{"instanceId":"codex","model":"gpt-5.4"},
  "runtimeMode":"full-access","interactionMode":"default",
  "branch": null | "feature/x", "worktreePath": null | "/…",
  "linkedPullRequest?": null | {"projectId","repository","number","url"},
  "pullRequests?": [ThreadPullRequestLink...], "branchPullRequest?": null | {...},
  "lineage":{"parentThreadId":null,"relationshipToParent":null|"fork"|"subagent","rootThreadId":"8c1e…"},
  "forkedFrom": null | {"type":"run","threadId","runId"} | {"type":"node","nodeId"} | {"type":"provider_thread","providerThreadId","providerTurnId?"},
  "activeProviderThreadId": null | "…",
  "historyOrigin?":"native"|"v1_import",
  "latestRunId": null | "…",
  "latestRunRequestedAt?": null|"<ISO>", "latestRunStartedAt?": null|"<ISO>", "latestRunCompletedAt?": null|"<ISO>",
  "activeRunId": null | "…",
  "activityRunStartedAt?": null|"<ISO>",
  "activityRunStatus?": null | "preparing"|"starting"|"running"|"waiting",
  "status": "idle"|"preparing"|"queued"|"starting"|"running"|"waiting"|"completed"|"interrupted"|"failed"|"cancelled"|"rolled_back",
  "lastError?": null|"…", "lastErrorClass?": null|"usage_limit"|"provider_error"|"transport_error"|"permission_error"|"validation_error"|"unknown",
  "usageLimitResetAt?": null|"<ISO string>",
  "pendingRuntimeRequest": null | {"id":"…","kind":"command|file-read|file-change|mcp-elicitation|permission|dynamic_tool_call|user_input|auth_refresh","createdAt":"<ISO>"},
  "latestVisibleMessage": null | {"id":"…","role":"user|assistant|system","text":"…","updatedAt":"<ISO>"},
  "latestUserMessageAt": null|"<ISO>",
  "hasActionableProposedPlan": false,
  "pendingBackgroundTasks": [ {"kind":"subagent|command|monitor|background_task","taskId":"…","description?":"…","childThreadId?":"…"} ],  // default []
  "providerInstanceHistory": ["codex","claudeAgent"],     // default []
  "itemCount": 42, "visibleItemCount": 40,
  "createdAt":"<ISO>","updatedAt":"<ISO>","archivedAt": null|"<ISO>",
  "settledOverride": null|"settled"|"active", "settledAt": null|"<ISO>",
  "unsettledAt?": null|"<ISO>", "snoozedUntil?": null|"<ISO>", "snoozedAt?": null|"<ISO>",
  "limitRecovery?": null | {"requestId?":"…","runId":"…","resetAt":"<ISO string>","autoResume":true,"snooze?":false},
  "pinnedAt?": null|"<ISO>", "autoSettleDisabledAt?": null|"<ISO>",
  "pinOrderKey?": null|"a0", "activeOrderKey?": null|"a1",
  "lastVisitedAt?": null|"<ISO>",
  "titleRegeneration?": null | {"requestId":"…","startedAt":"<ISO>"},
  "deletedAt": null|"<ISO>"
}
```
Useful derivations: "working" = `activityRunStatus != null` (or `status` in preparing/starting/running/waiting);
"needs you" = `pendingRuntimeRequest != null` or `hasActionableProposedPlan`; unread = `lastVisitedAt < updatedAt`
when `threadVisitedTracking` capability is on.

### 4.3 Shell reducer (mirror `applyShellStreamEvent`, `packages/client-runtime/src/state/shellReducer.ts:96-151`)

```
state: snapshot? (ShellSnapshot)
on "synchronized": mark live
on "snapshot":
   if resolvedRepositoryIdentityRoots present and state exists -> enrichment patch only (identity per root)
   else -> replace snapshot (keep prior non-null repositoryIdentity when new is null for same workspaceRoot)
on delta (has sequence):
   if sequence <= snapshot.snapshotSequence -> ignore (dedupe)
   project.updated  -> upsert by id; snapshotSequence = sequence
   project.removed  -> remove by id
   thread.updated   -> location=="active" ? upsert into threads : remove from threads; always remove from archivedThreads
   thread.removed   -> remove from threads and archivedThreads
```
The main shell keeps only active threads; archived threads have their own bounded RPCs
(`orchestration.getArchivedShellSnapshot` -> `{schemaVersion, snapshotSequence, projects, threads}`; or
`orchestration.subscribeArchivedShell` -> items `snapshot | thread.updated | thread.removed` without `location`,
`orchestrationV2.ts:2903-2928`).
Sequence numbers are monotonically increasing but **not contiguous** (they are global application-event sequences).

---

## 5. Thread detail read model

### 5.1 Subscribe

`orchestration.subscribeThread` payload (built in `packages/client-runtime/src/state/threads.ts:829-936`):
```json
{"threadId":"8c1e…","requestCompletionMarker":true}
```
- `afterSequence`: only when you hold a projection for that thread at that sequence (resume). Server replays events
  after it, or sends a fresh snapshot if the gap is too large / unsafe (`ws.ts:743-838`).
- `requestCompletionMarker`: only when `ServerConfig.threadResumeCompletionMarker === true`.
- `acceptBoundedSnapshot: true`: opt in to a *bounded* snapshot (recent window, pageable over HTTP
  `GET /api/orchestration/threads/{id}/history`). If you omit it you get the full projection. A first native version can
  omit it (simpler, at the cost of bigger snapshots on long threads).

Server emits (`ws.ts:725-756`): `snapshot` -> (`synchronized`) -> live `event`s. Resume: replayed `event`s -> (`synchronized`) -> live.
Tool-call updates are coalesced in 50 ms windows (only latest in-flight update per item survives, terminal updates never
dropped) (`apps/server/src/orchestration-v2/ThreadLiveEventCoalescer.ts`), so sequences have gaps.

### 5.2 Stream items (`OrchestrationV2ThreadStreamItem`, `orchestrationV2.ts:3113-3137`), discriminator `kind`

```jsonc
{"kind":"synchronized"}
{"kind":"snapshot","snapshotSequence":981,"projection": ThreadProjection,
  "historyCursor?": null|"opaque", "hasMoreHistory?": bool, "latestLocalTurnOrdinal?": null|int, "payloadBudgetExceeded?": bool}
{"kind":"event","sequence":982,"event": DomainEvent}
```
If `event.type` is unknown to you: skip it but still advance `lastSequence` (that is what the TS decode-only
`unknown-event` arm does). If a known type fails to decode, the TS client fails the subscription.

### 5.3 `OrchestrationV2ThreadProjection` (`orchestrationV2.ts:1639-1658`)

```jsonc
{
  "thread": AppThread,
  "runs": [Run], "attempts": [RunAttempt], "nodes": [ExecutionNode], "subagents": [Subagent],
  "providerSessions": [ProviderSession], "providerThreads": [ProviderThread], "providerTurns": [ProviderTurn],
  "runtimeRequests": [RuntimeRequest], "messages": [ConversationMessage], "plans": [PlanArtifact],
  "turnItems": [TurnItem],                       // all items (raw)
  "checkpointScopes": [CheckpointScope], "checkpoints": [Checkpoint],
  "contextHandoffs": [ContextHandoff], "contextTransfers": [ContextTransfer],
  "visibleTurnItems": [ProjectedTurnItem],       // THE TIMELINE: server-ordered, render this
  "updatedAt": "<ISO>"
}
```
Render from `visibleTurnItems` in order; mobile never rebuilds the chat from `messages`/`plans`/work collections
(`apps/mobile/src/lib/threadActivity.ts:1627-1640`, `buildThreadFeed`).

`ProjectedTurnItem` (`orchestrationV2.ts:1464`):
```jsonc
{"position":0,"visibility":"local"|"inherited"|"synthetic","sourceThreadId":"…","sourceItemId":"…","item": TurnItem}
```
(`inherited` rows come from a fork parent; `synthetic` are server-made.)

#### AppThread (`orchestrationV2.ts:356-431`)
Same fields as ThreadShell's thread part: `createdBy, creationSource, id, projectId, title (non-empty), providerInstanceId,
modelSelection, runtimeMode, interactionMode, branch, worktreePath, linkedPullRequest?, pullRequests?, branchPullRequest?,
activeProviderThreadId, historyOrigin?, lineage, forkedFrom, createdAt, updatedAt, archivedAt, settledOverride (default null),
settledAt (default null), unsettledAt?, snoozedUntil?, snoozedAt?, limitRecovery?, pinnedAt?, autoSettleDisabledAt?,
pinOrderKey?, activeOrderKey?, lastVisitedAt (default null), titleRegeneration?, rollbackRequestId?,
rollbackFailure?: null|{requestId,message}, deletedAt`.

#### Run (`orchestrationV2.ts:510-551`) — one user turn
```jsonc
{"id":"run-…","threadId":"…","ordinal":3,"providerInstanceId":"codex","modelSelection":{...},
 "providerThreadId": null|"…","userMessageId":"msg-…","rootNodeId": null|"…","activeAttemptId": null|"…",
 "status":"preparing|queued|starting|running|waiting|completed|interrupted|failed|cancelled|rolled_back",
 "queuePosition?": null|int, "queueHeld?": bool,
 "requestedAt":"<ISO>","startedAt": null|"<ISO>","completedAt": null|"<ISO>",
 "checkpointId": null|"…","contextHandoffId": null|"…",
 "restartContinuationOfRunId?":"…","workStartedAt?":"<ISO>",
 "restartCancelledBackgroundWork?":[{"kind":"subagent|shell|monitor|task","label":"…","id?":"…"}],
 "sourcePlanRef?":{"threadId","planId"},
 "delegatedCompletion?":{"disposition":"open|stopped|disposed","nextGeneration":1,"delivery":null|{"generation","messageId","taskIds":[...]}}}
```
Active run = last run with status in `preparing|starting|running|waiting` (`threadWorkflows.ts:39`). Working timer start =
`workStartedAt ?? startedAt ?? requestedAt`.

#### RunAttempt (`:564`)
`{id, nativeThreadId?, runId, attemptOrdinal, rootNodeId, providerInstanceId, providerThreadId, providerTurnId: null|id,
reason: "initial|steering_restart|retry|provider_recovery", status: "pending|running|completed|interrupted|failed|cancelled|superseded",
startedAt: null|ISO, completedAt: null|ISO}`

#### ExecutionNode (`:589`)
`{id, threadId, runId: null|id, parentNodeId: null|id, rootNodeId, kind: "root_turn|assistant_message|reasoning|plan|todo_list|tool_call|approval_request|user_input_request|subagent|hook|system",
status: "idle|pending|running|waiting|completed|interrupted|failed|cancelled|rolled_back", countsForRun: bool,
providerThreadId, providerTurnId, nativeItemRef: null|ProviderRef, runtimeRequestId: null|id, checkpointScopeId: null|id, startedAt, completedAt}`
`ProviderRef = {driver, nativeId: null|string, strength: "strong|weak|none", fingerprint?, ordinal?}`.

#### Subagent (`:630`)
`{id, threadId, runId, parentNodeId, origin: "provider_native|app_owned", createdBy, driver, providerInstanceId, providerThreadId,
childThreadId: null|id, nativeTaskRef, prompt, title: null|string, model: null|string, completionWake?, completionDelivery?,
status: "idle|pending|running|waiting|completed|failed|cancelled|interrupted", progress?, result: null|string, startedAt, completedAt, updatedAt}`

#### ProviderSession (`:692`) — carries capabilities used for steering/queue decisions
`{id, driver, providerInstanceId, status: "starting|ready|running|waiting|stopped|error", cwd, model: null|string,
capabilities: ProviderCapabilities, createdAt, updatedAt, lastError: null|string}`.
`ProviderCapabilities` (`:311`) is a struct of boolean groups: `sessions, threads, turns, streaming, tools, approvals,
planning, subagents, context, checkpointing, identity, runtimePolicy`. The ones a chat client reads:
`turns.supportsInterrupt`, `turns.supportsActiveSteering`, `turns.supportsSteeringByInterruptRestart`,
`turns.supportsQueuedMessages`, `sessions.supportsProviderSwitchingViaHandoff`. Decode the rest leniently.

#### ProviderThread (`:809`), ProviderTurn (`:918`)
ProviderThread: `{id, driver, providerInstanceId, providerSessionId, appThreadId, ownerNodeId, nativeThreadRef, nativeConversationHeadRef,
status: "not_loaded|idle|active|archived|closed|error", firstRunOrdinal, lastRunOrdinal, handoffIds: [], forkedFrom,
pendingBackgroundTasks (default []), contextUsage (default null; ThreadTokenUsageSnapshot), nativeMetadata (default null), createdAt, updatedAt}`.
`contextUsage` = `{usedTokens, maxTokens?, inputTokens?, cachedInputTokens?, outputTokens?, ..., cost?:{amount,currency}}`
(`providerRuntime.ts:263`) — source for a context-window meter.
ProviderTurn: `{id, providerThreadId, nodeId, runAttemptId, nativeTurnRef, ordinal, status: "pending|running|completed|interrupted|failed|cancelled",
startedAt, completedAt, tokenUsage?: {usedTokens, maxTokens?, inputTokens?, ..., updatedAt: string}, turnTokenUsage?}`.

#### RuntimeRequest (`:940`) — approvals and questions
```jsonc
{"id":"req-…","nodeId":"…","providerTurnId": null|"…","nativeRequestRef": null|ProviderRef,
 "kind":"command|file-read|file-change|mcp-elicitation|permission|dynamic_tool_call|user_input|auth_refresh",
 "status":"pending|resolved|expired|cancelled",
 "responseCapability":{"type":"live","providerSessionId":"…"} | {"type":"message"} | {"type":"not_resumable","reason":"…"},
 "createdAt":"<ISO>","resolvedAt": null|"<ISO>",
 "decision?":"accept|acceptForSession|acceptAlways|decline|cancel",
 "answers?": {"<questionId>": <json>}}
```

#### ConversationMessage (`:1028`)
```jsonc
{"notification?": Notification, "createdBy":"user","creationSource":"mobile","scheduledTaskId?":"…","senderThreadId?":"…",
 "id":"msg-…","threadId":"…","runId": null|"…","nodeId": null|"…","role":"user|assistant|system",
 "text":"…","context?": MessageContext,"attachments":[ChatAttachment],"streaming":false,
 "createdAt":"<ISO>","updatedAt":"<ISO>","delegatedCompletion?":{"parentRunId","generation","taskIds":[...]}}
```
Messages with `notification` or `delegatedCompletion` are automatic wake-ups, not user queue entries.

#### PlanArtifact (`:1092`), discriminator `kind`
```jsonc
{"id":"plan-…","threadId":"…","runId": null|"…","nodeId":"…","status":"draft|active|completed|superseded","detailInTurnItem?":true,
 "kind":"proposed_plan","markdown":"…"}
{"…base…","kind":"todo_list","steps":[{"id":"1","text":"…","status":"pending|running|completed","durationAnchorAt?":"<ISO string>","durationMs?":1234}],"explanation?":"…"}
```

#### Checkpoint (`:1115`)
`{id, threadId, scopeId, runId, nodeId, parentCheckpointId, ordinalWithinScope, appRunOrdinal: null|int, ref, status: "ready|missing|error|stale",
files: [{path, kind, additions, deletions}], capturedAt}`

### 5.4 TurnItem union (`orchestrationV2.ts:1229-1461`), discriminator `type`

Common fields on every item:
```jsonc
{"id":"item-…","threadId":"…","runId": null|"…","nodeId": null|"…",
 "providerThreadId": null|"…","providerTurnId": null|"…","nativeItemRef": null|ProviderRef,
 "parentItemId": null|"…",           // nested under another item (e.g. subagent work)
 "ordinal": 17,                      // sort key within thread
 "status":"idle|pending|running|waiting|completed|failed|cancelled|interrupted",
 "title": null|"…",
 "startedAt": null|"<ISO>","completedAt": null|"<ISO>","updatedAt":"<ISO>",
 "toolSurface?":"browser|computer",
 "toolIcon?": {"_tag":"website","pageUrl","faviconUrl?","faviconUrlDark?"} | {"_tag":"native-app","app":{"_tag":"app-id","appId"}|{"_tag":"display-name","displayName"}} | {"_tag":"themed-logo","logoUrl","logoUrlDark?"},
 "toolSource?": {"key","name","kind":"browser|computer|integration","icon?":ToolActivityIcon}}
```

Per-type fields:

| `type` | Extra fields |
|---|---|
| `user_message` | `createdBy`, `creationSource`, `messageId`, `scheduledTaskId?`, `senderThreadId?`, `inputIntent: "turn_start"\|"queued_turn"\|"steer"\|"promoted_queued_to_steer"`, `text`, `context?`, `attachments: [ChatAttachment]` |
| `assistant_message` | `messageId`, `text`, `attachments?`, `streaming: bool` |
| `reasoning` | `text`, `streaming: bool` |
| `proposed_plan` | `planId`, `markdown`, `streaming: bool` |
| `todo_list` | `planId`, `steps: [PlanStep]`, `explanation?` |
| `user_input_request` | `requestId`, `questions: [UserInputQuestion]`, `questionAnswer?: {requestId, questionTextById?, answers, attachmentsByQuestionId}`, `responseMode?: "message"` |
| `approval_request` | `requestId`, `requestKind: "command"\|"file-read"\|"file-change"\|"mcp-elicitation"\|"permission"`, `prompt?`, `appName?`, `options?: [{decision, label, warning?}]` |
| `command_execution` | `input` (the command), `output?` (**stripped on the wire**), `outputIndicatesFailure?: bool`, `exitCode?: int` |
| `file_change` | `fileName`, `additions?`, `deletions?`, `diffStr?`/`oldStr?`/`newStr?` (**stripped on the wire**), `changes?: [{operation, path, oldPath?, fileType?, mimeType?}]` |
| `file_search` | `pattern?`, `results?: [{fileName, line?, column?, preview?}]` |
| `web_search` | `patterns?: [string]`, `results?: [{title?, url?, snippet?}]` |
| `dynamic_tool` | `toolName: null\|string`, `viewedImagePath?`, `input: <json>` (large values become `{"summary":"…","truncated":true}`), `output?: <json>` (compacted) |
| `subagent` | `subagentId`, `origin`, `driver`, `providerInstanceId`, `childThreadId: null\|id`, `prompt` (≤32 KB), `progress?`, `result: null\|string` |
| `checkpoint` | `checkpointId`, `scopeId`, `files: [{path, kind, additions, deletions}]` |
| `run_interrupt_request` | `message` |
| `run_interrupt_result` | `message` |
| `system_notice` | `message` |
| `error` | `failure: {class, message, code: null\|string, retryable: null\|bool, resetAt?: null\|ISO string}`, `retry?: {attempt, maxAttempts: null\|int, retryDelayMs: null\|int}` |
| `compaction` | `driver: null\|string`, `summary?`, `beforeTokenCount?`, `afterTokenCount?` |
| `handoff` | `contextHandoffId`, `fromProviderThreadIds`, `toProviderThreadId`, `fromProviderInstanceIds`, `toProviderInstanceId`, `fromModelSelections?`, `toModel?`, `strategy`, (`summary` stripped) |
| `fork` | `source: {type:"run",threadId,runId}\|{type:"node",nodeId}\|{type:"provider_thread",providerThreadId,providerTurnId?}`, `targetThreadId`, `providerThreadId?` |
| `thread_created` | `targetThreadId`, `targetRunId: null\|id`, `targetProviderInstanceId`, `targetModel` |
| `notification` | `source: {kind:"delegated_task",taskIds,childThreadId?}\|{kind:"background_task",work:"subagent",childThreadId?}\|{kind:"background_command"}\|{kind:"monitor"}\|{kind:"background_task"}` (wire forms), `outcome: "completed"\|"failed"\|"cancelled"\|"updated"\|"unknown"`, `summary`, `detail?` |

Wire stripping (`apps/server/src/orchestration-v2/WireProjection.ts:66-117`): command `output` removed (failure kept as
`outputIndicatesFailure: true`), file_change diffs removed (fetch with `orchestration.getTurnDiff`), dynamic_tool
input/output summarized, subagent prompt/progress/result truncated to 32 KB, handoff summary removed,
contextHandoff `history`/`delivery` removed and `summaryText: ""`.

`UserInputQuestion` (`:1066`):
```jsonc
{"id":"q1","header":"Database","question":"Which DB?","options":[{"label":"Postgres","description":"…","value?":"pg"}],
 "multiSelect?":false,"allowCustomAnswer?":true,"required?":true}
```

`ChatAttachment` (`packages/contracts/src/chatAttachment.ts:155-214`), discriminator `type`:
```jsonc
{"type":"image","id":"att_abc","name":"shot.png","mimeType":"image/png","sizeBytes":12345,"source?":SnapShotSource}
{"type":"file","id":"att_def","name":"log.txt","mimeType":"text/plain","sizeBytes":999,"source?":{"_tag":"pasted-text"}}
{"type":"<other>","id":"…","name":"…","mimeType":"…","sizeBytes":0}     // unknown future type
```
`id` matches `^[a-z0-9_-]+$`i, ≤128 chars. To display: `assets.createUrl` with
`{"resource":{"_tag":"attachment","attachmentId":"<id>","fileName?":"…","mimeType?":"…","disposition?":"inline"|"attachment"}}`
-> `relativeUrl` (resolve against the HTTP base; it is signed, expires at `expiresAt` epoch-ms).

### 5.5 Domain events (`OrchestrationV2DomainEvent`, `orchestrationV2.ts:1488-1636`), discriminator `type`

Base fields on every event:
```jsonc
{"id":"evt-…","threadId":"…","runId?":"…","nodeId?":"…","driver?":"codex","providerInstanceId?":"codex","rawEventId?":"…",
 "occurredAt":"<ISO>","type":"…","payload":{…}}
```

| `type` | `payload` |
|---|---|
| `thread.created` | AppThread |
| `thread.archived`, `thread.unarchived`, `thread.deleted`, `thread.settled`, `thread.unsettled`, `thread.snoozed`, `thread.unsnoozed`, `thread.pinned`, `thread.auto-settle-set`, `thread.unpinned`, `thread.pin-reordered`, `thread.active-reordered`, `thread.visited`, `thread.marked-unread`, `thread.metadata-updated`, `thread.pull-request-synced`, `thread.runtime-mode-updated`, `thread.interaction-mode-updated`, `thread.model-selection-updated`, `thread.provider-switched` | AppThread (full replacement) |
| `run.created`, `run.updated` | Run |
| `run.background-work-cancelled` | `{runId, restartCancelledBackgroundWork: [...]}` |
| `run-attempt.created`, `run-attempt.updated` | RunAttempt |
| `node.updated` | ExecutionNode |
| `subagent.updated` | Subagent |
| `provider-session.attached`, `provider-session.updated` | ProviderSession |
| `provider-session.detached` | `{providerSessionId, detachedAt, reason?}` |
| `provider-thread.updated` | ProviderThread |
| `provider-turn.updated` | ProviderTurn |
| `runtime-request.updated` | RuntimeRequest |
| `message.updated` | ConversationMessage |
| `turn-item.updated` | TurnItem |
| `plan.updated` | PlanArtifact |
| `checkpoint-scope.created` | CheckpointScope |
| `checkpoint.captured` | Checkpoint |
| `checkpoint.rollback-requested` | `{scopeId, checkpointId, requestedAt}` |
| `context-handoff.updated` | ContextHandoff |
| `context-transfer.created`, `context-transfer.updated` | ContextTransfer |

**Streaming text has no delta events.** Assistant/reasoning/plan streaming is a sequence of `turn-item.updated` events
carrying the *full current item* (`text` grows, `streaming: true`), finished by one with `streaming: false` and
`status: "completed"`. Same for tool items (status `running` -> `completed|failed`). Replace by `id`.

Example live event chunk:
```json
{"_tag":"Chunk","requestId":3,"values":[
 {"kind":"event","sequence":1042,"event":{"id":"evt-9","threadId":"8c1e…","runId":"run-3","occurredAt":"2026-10-03T10:00:01.120Z",
  "type":"turn-item.updated","payload":{"type":"assistant_message","id":"item-77","threadId":"8c1e…","runId":"run-3","nodeId":"node-5",
   "providerThreadId":"pt-1","providerTurnId":"ptt-3","nativeItemRef":null,"parentItemId":null,"ordinal":31,"status":"running",
   "title":null,"startedAt":"2026-10-03T10:00:00.900Z","completedAt":null,"updatedAt":"2026-10-03T10:00:01.120Z",
   "messageId":"msg-88","text":"Looking at the login handler, the","streaming":true}}}]}
```

### 5.6 Thread reducer (mirror these exactly)

Per-subscription state: `projection?`, `lastSequence`, `status` (synchronizing/live/deleted), `awaitingCompletion`.

Stream handling (`packages/client-runtime/src/state/threads.ts:443-610`):
```
"synchronized" -> awaitingCompletion = false; status = live (if projection present)
"snapshot"     -> lastSequence = snapshotSequence; projection = snapshot.projection (replace); history meta from optional fields
"event"/unknown-> if sequence <= lastSequence: skip
                  lastSequence = sequence
                  if unknown type: skip
                  if no projection: only honor thread.deleted
                  if event.type == "thread.deleted": mark deleted, drop projection
                  else projection = apply(projection, event)
```
`apply` (`packages/client-runtime/src/state/orchestrationV2Projection.ts:153-286`):
- Ignore events whose `threadId != projection.thread.id`.
- `base = projection with updatedAt = event.occurredAt`.
- All `thread.*` types -> `thread = payload` (but `thread.visited` / `thread.marked-unread` do **not** bump `updatedAt`).
- `run.created|run.updated` -> upsert run by id, then recompute `visibleTurnItems` visibility (filter only, see below).
- `run.background-work-cancelled` -> set `restartCancelledBackgroundWork` on that run.
- `run-attempt.*` -> upsert attempt, recompute visibility.
- `node.updated`, `subagent.updated`, `provider-thread.updated`, `runtime-request.updated`, `message.updated`,
  `plan.updated`, `checkpoint-scope.created`, `checkpoint.captured`, `context-handoff.updated`, `context-transfer.*`
  -> upsert by `id` into the matching array.
- `provider-session.attached|updated` -> upsert; `provider-session.detached` -> remove where `id == payload.providerSessionId`.
- `provider-turn.updated` -> upsert, but keep the previous `tokenUsage` if the new payload omits it.
- `checkpoint.rollback-requested` -> no change.
- `turn-item.updated` -> upsert into `turnItems`; then if the item is visible, upsert a row
  `{visibility:"local", sourceThreadId:item.threadId, sourceItemId:item.id, item}` into `visibleTurnItems`, inserted
  before the first `local` row with `(ordinal > item.ordinal) || (ordinal == item.ordinal && id > item.id)` (string compare),
  else appended; if not visible remove its row. Renumber `position = index` after any change. If the item (or the
  previous version) is a `run_interrupt_request`, recompute visibility of all rows first.

Visibility (`packages/shared/src/orchestrationV2Timeline.ts:42-128`). An item is hidden when:
1. its run has status `rolled_back`; or
2. it is a `user_message` with `inputIntent == "queued_turn"` whose run is `cancelled`; or
3. it is a `run_interrupt_result` whose `(runId, nodeId)` matches a `superseded` attempt's `(runId, rootNodeId)` and there is
   no `run_interrupt_request` item with that `runId`.
Recompute only removes `local` rows; `inherited`/`synthetic` rows are left as the server sent them.

### 5.7 Derived UI state

Pending approvals / questions (`packages/client-runtime/src/state/threadRequests.ts:45-97`): for each
`runtimeRequests[i]` with `status == "pending"`:
- `kind == "user_input"`: find last `turnItems` item `type == "user_input_request" && requestId == request.id`; show its
  `questions`. Dismissible when `item.responseMode == "message"` or `responseCapability.type == "message"`.
- `kind in {auth_refresh, dynamic_tool_call}`: skip.
- otherwise (approval): find last `approval_request` item with that `requestId` for `prompt`, `appName`, `options`.
  Respond only if `responseCapability.type == "live"`. Default options when absent
  (`apps/mobile/src/features/threads/PendingApprovalCard.tsx:21-25`):
  `accept` "Allow once", `acceptForSession` "Allow session", `decline` "Decline".

Queue (`packages/client-runtime/src/state/threadWorkflows.ts:111-161`):
- queued runs = `runs` with `status == "queued"`, excluding runs whose `userMessageId` belongs to a message with
  `delegatedCompletion` or `notification`; sorted by `(queuePosition ?? ordinal)`, then `ordinal`; text/attachments
  from the message with `id == run.userMessageId`.
- `isHeld` = any queued run with `queueHeld == true` (show "Resume queue" -> `queue.resume`).
- `canReorder` = active session `capabilities.turns.supportsQueuedMessages`.
- `canPromoteToSteer` = active run `running` with a `running` providerTurn on its `activeAttemptId`, and
  `supportsActiveSteering || supportsSteeringByInterruptRestart`.
- Active session resolution: provider thread of the active run (or `thread.activeProviderThreadId`) -> its
  `providerSessionId` -> `providerSessions` (`threadWorkflows.ts:66-90`).

Interruptible run: last run in `preparing|starting|running|waiting`; if none, the latest run when it still has pending
background work (`commands.ts:770-806`, `derivePendingBackgroundWork` in `packages/shared/src/orchestrationV2PendingBackgroundWork.ts`).

---

## 6. Commands (`orchestration.dispatchCommand`)

Payload = one `OrchestrationV2Command` object (`orchestrationV2.ts:2437-2853`), discriminated by `type`.
Success = `{"sequence": <int>}` (sequence of the committed events; `0` when the client did nothing).
Every command has `commandId` (UUID string). Commands are recorded with a command receipt; mobile re-sends with the
**same** `commandId` when retrying (outbox), and derives deterministic ids for auxiliary commands
(e.g. `${commandId}:model-selection`, `commands.ts:589`).

### 6.1 Send a message to an existing thread: `message.dispatch` (`orchestrationV2.ts:2651-2687`)

```jsonc
{
  "type": "message.dispatch",
  "commandId": "c3c1d6c2-…",                     // required
  "createdBy": "user",                           // required ("user"|"agent"|"system")
  "creationSource": "mobile",                    // required ("web"|"mobile"|"mcp"|"provider"|"server")
  "threadId": "8c1e…",                           // required
  "messageId": "5f0e…",                          // required (UUID)
  "text": "Please fix the failing test",         // required, plain String (not trimmed), ≤120000 chars
  "attachments": [],                             // required array of ChatAttachment (already uploaded ids)
  "dispatchMode": {"type": "start_immediately"}, // required, see below
  "context?": {"version":1,"records":[…]},       // OrchestrationMessageContext; omit
  "titleSeed?": "Please fix the failing test",   // first message only: seeds a temp title, server generates a real one
  "modelSelection?": {"instanceId":"codex","model":"gpt-5.4"},
  "sourcePlanRef?": {"threadId":"…","planId":"…"},   // "implement this plan"
  "deliveryIntent?": "auto"|"steer"|"restart",    // only with serverResolvedCommandContext
  "manualContinuationOfRunId?": "run-…"
  // also exist but client doesn't set: notification, scheduledTaskId, senderThreadId, restartContinuationOfRunId,
  // usageLimitContinuationOfRunId, usageLimitRecoveryRequestId, delegatedCompletion
}
```
`dispatchMode` (`:2680-2686`):
```jsonc
{"type":"start_immediately"}
{"type":"queue_after_active"}
{"type":"steer_active","targetRunId":"run-…"}
{"type":"restart_active","targetRunId":"run-…"}
{"type":"defer_start"}
```
`message.dispatch` has **no** `runtimeMode`/`interactionMode`. Mobile first sends `thread.runtime-mode.set` /
`thread.interaction-mode.set` when the composer's values differ from the thread's
(`apps/mobile/src/state/use-thread-outbox-drain.ts:789-818`), then the message.

How client-runtime chooses `dispatchMode` (`packages/client-runtime/src/operations/commands.ts:621-768`, `startThreadTurn`):
- Mobile UI mode: `undefined` when idle; when a turn is running, `"queue"` (default follow-up behavior) or `"auto"`
  (steer) (`use-thread-composer-state.ts:657-668`, `lib/followUpBehavior.ts`). The outbox maps `undefined` -> `"start"`
  (`use-thread-outbox-drain.ts:901`).
- `"start"` -> `{"type":"start_immediately"}`, no `deliveryIntent`.
- If `capabilities.serverResolvedCommandContext`: `"queue"` -> `queue_after_active`; anything else -> `start_immediately`
  plus `deliveryIntent: <mode>` ("auto"|"steer"|"restart"); `titleSeed` always sent (server ignores it after the first message).
- Without that capability (older server) the client reads the projection: no active run -> `start_immediately`;
  `steer` -> `steer_active(activeRun.id)`; `restart` -> `restart_active`; `queue` -> `queue_after_active`;
  `auto` -> steer if `supportsActiveSteering`, else queue if `supportsQueuedMessages`, else restart if
  `supportsSteeringByInterruptRestart`, else queue. `titleSeed` only if `projection.messages` is empty.

Mobile example (idle thread, one uploaded image):
```json
{"_tag":"Request","id":12,"tag":"orchestration.dispatchCommand","headers":[],"payload":{
 "type":"message.dispatch","commandId":"0d0b5c40-8a8b-4b0e-9d1e-3a8f6f0e2c11","createdBy":"user","creationSource":"mobile",
 "threadId":"8c1e5d1a-…","messageId":"5f0e2a77-…","text":"What's in this screenshot?",
 "attachments":[{"type":"image","id":"att_k2j3","name":"IMG_0001.png","mimeType":"image/png","sizeBytes":482113}],
 "titleSeed":"What's in this screenshot?","modelSelection":{"instanceId":"claudeAgent","model":"claude-opus-4-6"},
 "deliveryIntent":"auto","dispatchMode":{"type":"start_immediately"}}}
```
Response: `{"_tag":"Exit","requestId":12,"exit":{"_tag":"Success","value":{"sequence":1043}}}`.
The resulting `run.created`, `message.updated`, `turn-item.updated` (user_message), etc. arrive on the thread subscription.

### 6.2 New thread (+ first message): `orchestration.launchThread`

Mobile never sends a bare `thread.create`; it calls `startThreadTurn` with a `bootstrap`, which becomes `launchThread`
(`apps/mobile/src/lib/projectThreadStartTurn.ts:44-90` -> `commands.ts:636-689`).

`OrchestrationV2ThreadLaunchInput` (`orchestrationV2.ts:2930-2970`):
```jsonc
{
  "commandId": "UUID",
  "creationSource?": "mobile",
  "threadId?": "UUID",                 // client-generated so it can navigate immediately
  "reuseExistingThread?": true,        // only when launching into an existing empty thread
  "projectId": "0b2f…",
  "title": "Fix the login bug",        // TrimmedNonEmptyString; mobile uses deriveThreadTitleSeed(text)
  "generateTitle?": true,              // mobile: true (titleSeed present)
  "modelSelection": {"instanceId":"codex","model":"gpt-5.4"},
  "runtimeMode": "full-access",
  "interactionMode": "default",
  "workspaceStrategy":
      {"type":"root","branch?":"main"}                                         // project checkout ("local")
    | {"type":"existing_worktree","worktreePath":"/…","branch?":"…"}
    | {"type":"worktree","baseRef":"main","branch?":"t3/abc123","startFromOrigin?":true},  // new git worktree
  "initialMessage?": {"messageId?":"UUID","text":"…","context?":{...},"attachments":[ChatAttachment...]}
}
```
Mobile strategy mapping (`commands.ts:647-670`): worktree mode -> `worktree` with `baseRef = selected branch`,
`branch = generated temp branch name`; local mode with a worktreePath -> `existing_worktree`; otherwise `root` with optional
`branch`. Success: `{"threadId":"…","projection": ThreadProjection,"resumed": bool}` — seed your thread state with the
projection, then `subscribeThread`. The shell receives `thread.updated` for the new thread.

Thread without a repository: `projects.ensureScratch` `{}` -> `{"projectId":"…"}` (needs `ServerConfig.scratchWorkspaceRoot`).

(For completeness, `thread.create` exists: `{type:"thread.create", createdBy, creationSource, commandId, threadId, projectId,
title, modelSelection, runtimeMode, interactionMode, branch: null|string, worktreePath: null|string, importedNativeThread?}`,
`orchestrationV2.ts:2438-2460`; built by `commands.ts:388-405`.)

### 6.3 Interrupt: `run.interrupt` (`orchestrationV2.ts:2715-2722`, built `commands.ts:770-806`)
```json
{"type":"run.interrupt","commandId":"UUID","threadId":"…","runId":"<interruptible run id>","holdQueue":true}
```
`reason?` optional. Mobile passes the composer's `interruptibleRunId` (`ThreadRouteScreen.tsx:676-687`); client-runtime
always sends `holdQueue: true` (queued runs stay held; resume with `queue.resume`).

### 6.4 Approvals and questions: `runtime-request.respond` (`:2759-2767`, built `commands.ts:808-833`)
Approval:
```json
{"type":"runtime-request.respond","commandId":"UUID","threadId":"…","requestId":"req-…","decision":"accept"}
```
`decision` ∈ `accept | acceptForSession | acceptAlways | decline | cancel` (`providerPolicy.ts:51-58`).

User input answers:
```json
{"type":"runtime-request.respond","commandId":"UUID","threadId":"…","requestId":"req-…",
 "answers":{"q1":"pg","q2":["a","b"],"q3":"free text"},
 "attachmentsByQuestionId?":{"q3":[ChatImageAttachment|ChatFileAttachment]}}
```
Answer values (`apps/mobile/src/lib/threadActivity.ts:319-373, 1611-1625`): per question id, a custom text answer if given
(and `allowCustomAnswer != false`), else the selected option's `value ?? label` (string), or an array of them when
`multiSelect`. Attachments require `capabilities.questionAttachments`.

Dismiss a message-mode question: `{"type":"thread.user-input.dismiss","commandId","threadId","requestId"}` (`:2768`).

### 6.5 Queue (`:2723-2758`, built `commands.ts:940-1019`)
```jsonc
{"type":"queued-run.cancel","commandId","threadId","runId"}
{"type":"queued-run.reorder","commandId","threadId","runId","beforeRunId": null|"run-…"}   // null = move to end
{"type":"queued-message.promote-to-steer","commandId","threadId","queuedRunId","targetRunId":"<active run>"}
{"type":"queued-run.edit","commandId","threadId","runId","text","attachments?":[...],"context?":{...}}   // attachments = full replacement
{"type":"queue.resume","commandId","threadId"}
```

### 6.6 Thread lifecycle and settings
```jsonc
{"type":"thread.archive","commandId","threadId"}
{"type":"thread.unarchive","commandId","threadId"}
{"type":"thread.delete","commandId","threadId"}
{"type":"thread.runtime-mode.set","commandId","threadId","runtimeMode":"approval-required"}
{"type":"thread.interaction-mode.set","commandId","threadId","interactionMode":"plan"}
{"type":"thread.model-selection.set","commandId","threadId","modelSelection":{...}}   // with serverResolvedCommandContext; else client picks via modelSelectionCommandType (may be "provider.switch")
{"type":"provider.switch","commandId","threadId","modelSelection":{...}}
{"type":"thread.metadata.update","commandId","threadId","title?":"…","regenerateTitle?":true,"branch?":null|"…","worktreePath?":null|"…","limitRecovery?":…,"linkedPullRequest?":…}
{"type":"thread.visit","commandId","threadId","visitedAt":"<ISO string>"}   // typically shell.updatedAt; requires threadVisitedTracking
{"type":"thread.mark-unread","commandId","threadId"}
{"type":"thread.settle","commandId","threadId","settledAt?":"<ISO>"} / {"type":"thread.unsettle","commandId","threadId","reason":"user"}
{"type":"thread.snooze","commandId","threadId","snoozedUntil":"<ISO string>"} / {"type":"thread.unsnooze",...,"reason":"user"}
{"type":"thread.pin","commandId","threadId","orderKey?":"a0"} / {"type":"thread.unpin","commandId","threadId"}
{"type":"checkpoint.rollback","commandId","threadId","scopeId","checkpointId","restoreFiles?":true}
{"type":"provider-session.detach","commandId","threadId","providerSessionId","reason?":"client-requested"}   // "stop session"
{"type":"thread.fork","createdBy":"user","creationSource":"mobile","commandId","sourceThreadId","targetThreadId","sourcePoint":{"type":"run","runId"},"title?":"…"}
```
Gate the optional ones on the capability flags in §3.1 (settlement, snooze, pinning, visited tracking, title regeneration).
Archive/delete effects: shell gets `thread.updated {location:"archive"}` / `thread.removed`; the thread stream gets
`thread.archived` / `thread.deleted` (the TS client drops the thread state on `thread.deleted`).

---

## 7. Attachments upload flow (mobile)

Capability `attachmentUploads == true` (all current servers):
1. `attachments.createUploadUrl` with
   - image: `{"name":"IMG_0001.png","mimeType":"image/png","sizeBytes":482113}` (`type` may be omitted or `"image"`;
     `mimeType` must be one of `image/gif|image/jpeg|image/png|image/webp`; ≤10 MiB)
   - file: `{"type":"file","name":"log.txt","mimeType":"text/plain","sizeBytes":999}` (1 byte..50 MiB, also capped by
     `capabilities.fileAttachments.maxUploadBytes`) (`packages/contracts/src/assets.ts:87-118`)
   -> `{"attachmentId":"att_…","relativeUrl":"/api/attachments/upload/…(signed)","expiresAt":1759485600000}` (TTL 10 min;
   route prefix `ATTACHMENT_UPLOAD_ROUTE_PREFIX` in `apps/server/src/assets/AttachmentUpload.ts:36`).
2. `POST` raw bytes to `httpBase + relativeUrl` with `Content-Type: <mimeType>` (binary body, no multipart; the URL is
   signed, no auth header needed) (`apps/mobile/src/lib/attachmentUpload.ts:257-300`). Expect 2xx.
3. Reference it in the message as a `ChatAttachment`: `{"type":"image"|"file","id":"<attachmentId>","name","mimeType","sizeBytes"}`
   (`attachmentUpload.ts:187-205`). Images picked via Files should still be sent as `type:"image"`.
4. On abandon: `attachments.delete {"attachmentId"}`. To verify an old pending upload still exists: `assets.createUrl`
   with `{"resource":{"_tag":"attachment","attachmentId":"…"}}` — `AssetAttachmentNotFoundError` means re-upload
   (`packages/client-runtime/src/state/attachments.ts:47-97`).

Legacy servers (no `attachmentUploads`): put inline uploads in the turn instead; client-runtime then calls
`assets.persistChatAttachments {threadId, messageId, attachments:[{"type":"image","name","mimeType","sizeBytes","dataUrl":"data:image/png;base64,…"}]}`
and substitutes the returned `ChatAttachment`s (`commands.ts:277-302`).

Helm voice: upload the clip the same way (`type:"file"`), then `voice.transcribe {"attachmentId","threadId?","durationSeconds?"}`
-> `{"text"}`; the server deletes the clip (`packages/contracts/src/voiceTranscription.ts`). Gate on `capabilities.voiceTranscription`.

---

## 8. Porting checklist / gotchas

1. Append `orchestrationProtocol=2` to the WS URL, authenticate with a fresh `wsTicket` per connection.
2. Send `Ack` after every `Chunk` of every stream, or the stream stalls.
3. Send `Ping` periodically (5 s) and reconnect on missing `Pong`; on reconnect, resubscribe with `afterSequence`.
4. Decode envelopes that may be arrays.
5. All `kind`/`type`/status enums need an unknown fallback; arrays of providers and context records should drop
   undecodable elements; unknown thread event types must still advance `lastSequence`.
6. Dates: `DateTimeUtc` fields are ISO strings with milliseconds; `IsoDateTime` fields are plain strings.
7. `optional` keys are omitted (not null); `NullOr` keys are present with `null`. When encoding commands, omit absent
   optionals and send `null` for required `NullOr` (e.g. `thread.create.branch`, `queued-run.reorder.beforeRunId`).
8. Treat shell `snapshot` frames with `resolvedRepositoryIdentityRoots` as enrichment only.
9. Render the thread from `projection.visibleTurnItems`; maintain it with the turn-item upsert/visibility rules in §5.6.
10. Streaming text = repeated full `turn-item.updated` payloads; replace by item id.
11. Command output and file diffs are not in the stream; fetch diffs via `orchestration.getTurnDiff`
    (`toTurnCount` = the checkpoint's `appRunOrdinal`, `fromTurnCount = max(0, toTurnCount - 1)` for one turn
    (`packages/client-runtime/src/state/threadCheckpoints.ts:43`, `apps/mobile/src/features/review/useReviewSections.ts:136`);
    result `{threadId, fromTurnCount, toTurnCount, diff: <unified diff string>}`).
12. Generate `commandId`, `messageId`, `threadId` as UUID v4; reuse `commandId` on retry of the same user action.
13. `message.dispatch` requires `createdBy` and `creationSource` (use `"user"` / `"mobile"`); `launchThread` takes only
    `creationSource`.
