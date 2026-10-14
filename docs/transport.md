# Helm / T3 Code server: wire-level transport reference for a native iOS client

Repo: `/Users/you/Documents/Projects/t3code` (branch `helm`). The installed Effect is
`effect@4.0.0-rc.115`, which matches `.repos/effect-smol` except for a pnpm patch to `RpcClient`
(`patches/effect@4.0.0-rc.115.patch`). Every file:line below is relative to the repo root.
Effect RPC sources: `.repos/effect-smol/packages/effect/src/unstable/rpc/*` (same content as
`node_modules/.pnpm/effect@4.0.0-rc.115_patch.../src/...`).

---------------------------------------------------------------------------------------------------

## TL;DR flow for a native client (direct / tailnet, bearer auth, no DPoP)

```
1. Parse pairing URL           http://100.x.y.z:3783/pair#token=ABCD2345EFGH
                               -> httpBase = http://100.x.y.z:3783/ , wsBase = ws://100.x.y.z:3783/
                                  credential = ABCD2345EFGH  (token in #fragment, or ?token= fallback)
2. GET  /.well-known/t3/environment        (no auth)  -> environmentId, label, orchestrationProtocolVersion (must be 2), capabilities
3. POST /oauth/token  (application/x-www-form-urlencoded, NOT JSON)
        grant_type=urn:ietf:params:oauth:grant-type:token-exchange
        subject_token=<credential>
        subject_token_type=urn:t3:params:oauth:token-type:environment-bootstrap
        requested_token_type=urn:ietf:params:oauth:token-type:access_token
        scope=orchestration:read orchestration:operate terminal:operate review:write relay:read   (optional)
        client_label=...&client_device_type=mobile&client_os=iOS                                    (optional)
   -> {"access_token":"<b64url>.<sig>","issued_token_type":"urn:ietf:params:oauth:token-type:access_token",
       "token_type":"Bearer","expires_in":2592000,"scope":"orchestration:read ..."}
   STORE access_token (Keychain). It is a 30-day bearer. Pairing credential is single-use, 5-minute TTL.
4. Every HTTP call: Authorization: Bearer <access_token>
   (orchestration snapshot routes also need header  x-t3-orchestration-protocol: 2)
5. Each socket connect: POST /api/auth/websocket-ticket (Bearer, empty body) -> {"ticket":"...","expiresAt":"ISO"}
6. Open  ws://host:3783/ws?wsTicket=<ticket>&orchestrationProtocol=2&clientSurface=mobile&...
   (Alternative accepted by the server: no ticket, send `Authorization: Bearer <token>` header on the upgrade.)
7. Speak Effect RPC JSON: one JSON object per WS text frame. Send {"_tag":"Ping"} every 5 s, ACK every Chunk.
8. First RPC the official client sends: Request tag "subscribeServerConfig" (stream); wait for the
   first chunk value {"version":1,"type":"snapshot","config":{...}}. Then "server.probe" {} (or "server.getConfig").
```

---------------------------------------------------------------------------------------------------

## 1. Pairing and authentication

### 1.1 Pairing URL format

Built on the server by `issueStartupPairingUrl`, `apps/server/src/auth/EnvironmentAuth.ts:1045-1055`:

```ts
const url = new URL(baseUrl);
url.pathname = "/pair";
url.searchParams.delete("token");
url.hash = new URLSearchParams([["token", issued.credential]]).toString();
```

Built in the web/desktop Connections settings (QR code) by `apps/web/src/components/settings/pairingUrls.ts:4-8`
(`resolveDesktopPairingUrl`) → `setPairingTokenOnUrl` (`packages/shared/src/remote.ts:165-170`):

- Direct form:  `http(s)://<host>:<port>/pair#token=<CREDENTIAL>`
  e.g. `http://100.101.102.103:3783/pair#token=7K3MZQ9XH2PA`
- Hosted form (HTTPS endpoints only, `apps/web/src/hostedPairing.ts:73-87`):
  `https://app.t3.codes/pair?host=<urlencoded backend url>&label=<optional>#token=<CREDENTIAL>`

Parser: `resolveRemotePairingTarget`, `packages/shared/src/remote.ts:188-245`:

- Scheme must be one of `http: https: ws: wss:` (`remote.ts:6`).
- If `?host=` is present together with a token → hosted form: the backend is `host` (normalized; https:// is
  prepended if no scheme) (`remote.ts:172-186, 206-217`).
- Otherwise the token is read from the **fragment** `#token=` first, then the query `?token=` (`getPairingTokenFromUrl`, `remote.ts:144-152`).
- httpBaseUrl = origin with path `/`, ws→http / wss→https. wsBaseUrl = same origin with http→ws / https→wss (`remote.ts:106-130`).
- Manual entry is also supported: `{host, pairingCode}` → the code is the credential (`remote.ts:230-244`).

Credential format: 12 characters from the alphabet `23456789ABCDEFGHJKLMNPQRSTUVWXYZ`
(`apps/server/src/auth/PairingGrantStore.ts:258-259`). TTL is 5 minutes (`PairingGrantStore.ts:239`), or 24 h for the
dev startup token. It is **consumed on first exchange** (`bootstrapCredentials.consume`, `EnvironmentAuth.ts:786-789`).
A credential issued through `/api/auth/pairing-token` or the Helm tailnet flow carries the standard scopes
(`EnvironmentAuth.ts:982-987`). The startup URL carries the administrative scopes (`EnvironmentAuth.ts:989-995`).

Mobile URL schemes (`apps/mobile/app.config.ts:79-95`) are `t3code`, `t3code-preview`, and `t3code-dev`. The pairing
flow itself does not use them. Scanned QR codes and pasted links are plain http(s) URLs handed to
`connectPairingUrl` (`apps/mobile/src/connection/onboarding.ts:13-21`).

### 1.2 HTTP API routes (contract)

Contract: `packages/contracts/src/environmentHttp.ts:429-660`. Handlers: `apps/server/src/auth/http.ts:230-500`.

| Name | Method + path | Auth | Request | Response |
|---|---|---|---|---|
| descriptor | `GET /.well-known/t3/environment` (`environmentHttp.ts:430`) | none | – | `ExecutionEnvironmentDescriptor` |
| session | `GET /api/auth/session` (`:437`) | optional | – | `AuthSessionState` (never 401; returns `authenticated:false`) |
| browserSession | `POST /api/auth/browser-session` (`:444`) | – | JSON `{"credential":"..."}` | sets an httpOnly cookie, for browsers only |
| **token** | `POST /oauth/token` (`:451`) | – (optional `DPoP` header) | **form-urlencoded** `AuthTokenExchangeRequest` | `AuthAccessTokenResult` |
| **webSocketTicket** | `POST /api/auth/websocket-ticket` (`:459`) | required | none | `{ticket, expiresAt}` |
| pairingCredential | `POST /api/auth/pairing-token` (`:466`) | `access:write` | JSON `{label?, scopes?}` | `{id, credential, label?, expiresAt}` |
| pairingLinks / revokePairingLink / clients / revokeClient / revokeOtherClients | `/api/auth/...` (`:474-509`) | `access:read`/`access:write` | | |
| shellSnapshot | `GET /api/orchestration/shell` (`:528`) | required + header `x-t3-orchestration-protocol: 2` | | `OrchestrationV2ShellSnapshot` |
| threadSnapshot | `GET /api/orchestration/threads/:threadId` (`:535`) | same | | |
| threadBoundedSnapshot | `GET /api/orchestration/threads/:threadId/bounded` (`:543`) | same | | |
| threadHistoryPage | `GET /api/orchestration/threads/:threadId/history?cursor=...` (`:551`) | same | | |
| projects | `GET /api/projects`, `POST /api/projects/mutate` (`:562-575`) | required | | |
| PR diff | `POST /api/pull-requests/diff` (`:579`) | required | | |

#### Token exchange (the pairing step)

Schema, `packages/contracts/src/auth.ts:117-121, 186-205`:

```ts
AuthTokenExchangeRequest = Struct({
  grant_type: "urn:ietf:params:oauth:grant-type:token-exchange",
  subject_token: TrimmedNonEmptyString,                                  // the pairing credential
  subject_token_type: "urn:t3:params:oauth:token-type:environment-bootstrap",
  requested_token_type: "urn:ietf:params:oauth:token-type:access_token",
  scope?: string,            // space separated (RFC 6749); must be a subset of the grant
  client_label?: string,
  client_device_type?: "desktop"|"mobile"|"tablet"|"bot"|"unknown",
  client_os?: string,
}).pipe(HttpApiSchema.asFormUrlEncoded())

AuthAccessTokenResult = Struct({
  access_token: string,
  issued_token_type: "urn:ietf:params:oauth:token-type:access_token",
  token_type: "Bearer" | "DPoP",
  expires_in: number,       // seconds
  scope: string,            // space separated
})
```

The body must be `Content-Type: application/x-www-form-urlencoded`. HttpApiBuilder picks the decoder by content-type,
so a JSON body gets **415 Unsupported content-type** (`effect/src/unstable/httpapi/HttpApiBuilder.ts:747-752, 787-789`).

Example:
```
POST /oauth/token HTTP/1.1
Host: 100.101.102.103:3783
Content-Type: application/x-www-form-urlencoded

grant_type=urn%3Aietf%3Aparams%3Aoauth%3Agrant-type%3Atoken-exchange&subject_token=7K3MZQ9XH2PA&subject_token_type=urn%3At3%3Aparams%3Aoauth%3Atoken-type%3Aenvironment-bootstrap&requested_token_type=urn%3Aietf%3Aparams%3Aoauth%3Atoken-type%3Aaccess_token&scope=orchestration%3Aread+orchestration%3Aoperate+terminal%3Aoperate+review%3Awrite+relay%3Aread&client_label=Helm+iOS&client_device_type=mobile&client_os=iOS

HTTP/1.1 200 OK
cache-control: no-store
pragma: no-cache
content-type: application/json

{"access_token":"eyJ2IjoxLCJraW5kIjoic2Vzc2lvbiIs...Q.Xk2...","issued_token_type":"urn:ietf:params:oauth:token-type:access_token","token_type":"Bearer","expires_in":2591999,"scope":"orchestration:read orchestration:operate terminal:operate review:write relay:read"}
```

Server handler: `apps/server/src/auth/http.ts:312-385` → `exchangeBootstrapCredentialForAccessToken`,
`apps/server/src/auth/EnvironmentAuth.ts:804-859`. Without a DPoP header it issues method `bearer-access-token`
with the default TTL of **30 days** (`apps/server/src/auth/SessionStore.ts:423`). There is no refresh token. When the
bearer expires or is revoked (Settings → Connections → clients), the client has to pair again.

Scopes (`packages/contracts/src/auth.ts:81-115`): `orchestration:read`, `orchestration:operate`, `terminal:operate`,
`review:write`, `access:read`, `access:write`, `relay:read`, `relay:write`. The mobile app requests
`AuthStandardClientScopes` = `orchestration:read orchestration:operate terminal:operate review:write relay:read`
(`apps/mobile/src/connection/platform.ts:168-173`). The scope parameter can be omitted, in which case the grant's
scopes are used. Asking for more than the grant holds returns 400 `{"_tag":"EnvironmentRequestInvalidError","code":"invalid_request","reason":"scope_not_granted",...}`.

Client code: `bootstrapRemoteBearerSession`, `packages/client-runtime/src/authorization/remote.ts:115-140`. Mobile
metadata (`apps/mobile/src/lib/authClientMetadata.ts`): label "T3 Code Mobile", deviceType mobile/tablet, os "iOS".
Onboarding order (`packages/client-runtime/src/connection/onboarding.ts:87-125`):
`resolvePairingTarget` → `fetchRemoteEnvironmentDescriptor` → protocol-compat check → `bootstrapRemoteBearerSession`
→ store `BearerConnectionCredential{token: access_token}` plus profile `{connectionId:"bearer:<environmentId>", environmentId, label, httpBaseUrl, wsBaseUrl}`.

#### Token format (opaque to clients, documented here for reference)
`base64url(JSON claims) + "." + HMAC signature` (`SessionStore.ts:425-436, 649-690`). Claims:
`{v:1, kind:"session", sid, sub, scopes, method, jkt?, iat, exp}` with epoch milliseconds. WebSocket tickets use
the same format with `{v:1, kind:"websocket", sid, iat, exp}` (`SessionStore.ts:438-444, 840-879`). Treat both as opaque.

### 1.3 Sending the credential

Server credential selection, `apps/server/src/auth/EnvironmentAuth.ts:554-598`. Precedence:
1. session cookie (browser)
2. `Authorization: Bearer <token>`
3. `Authorization: DPoP <token>` (requires a `DPoP` proof header, used by relay connections only)
4. legacy cookie

A native client only needs `Authorization: Bearer <access_token>`. Client side:
`packages/client-runtime/src/state/environmentHttpAuth.ts:64-95` (`{ authorization: "Bearer " + token }`), plus
`x-t3-orchestration-protocol: 2` on the orchestration snapshot routes (`environmentHttpAuth.ts:26-35`,
`packages/contracts/src/environment.ts:13-16`).

401 response body (`packages/contracts/src/environmentHttp.ts:134-152`):
```json
{"_tag":"EnvironmentAuthInvalidError","code":"auth_invalid","reason":"missing_credential"|"invalid_credential","traceId":"..."}
```
403: `{"_tag":"EnvironmentScopeRequiredError","code":"insufficient_scope","requiredScope":"access:write","traceId":"..."}`.
500: `{"_tag":"EnvironmentInternalError","code":"internal_error","reason":"...","traceId":"..."}`.

Session check: `GET /api/auth/session` with Bearer →
`{"authenticated":true,"auth":{"policy":"remote-reachable","bootstrapMethods":["one-time-token"],"sessionMethods":[...],"sessionCookieName":"..."},"scopes":[...],"sessionMethod":"bearer-access-token","expiresAt":"2026-11-02T..Z"}`.
If the token is bad, the response is `{"authenticated":false,"auth":{...}}` with status 200 (`EnvironmentAuth.ts:691-710`).

Origin is not checked on HTTP or WS, so a native client needs no CORS handling. The CORS allow-list lives in `apps/server/src/httpCors.ts`.

---------------------------------------------------------------------------------------------------

## 2. WebSocket connection

Route: `GET /ws`, `apps/server/src/ws.ts:3748-3804`.

Order of checks on the upgrade:
1. **Query `orchestrationProtocol=2` is required** (`ws.ts:509-514, 3760-3768`). If it is missing or wrong the
   server answers HTTP **426** with JSON
   `{"code":"orchestration_protocol_incompatible","message":"Update this client ...","orchestrationProtocolVersion":2}`
   (constants in `packages/contracts/src/environment.ts:13-16`; the client appends it in
   `packages/client-runtime/src/connection/compatibility.ts:38-42`, called from `connection/resolver.ts:300-308`).
2. Auth, `authenticateWebSocketUpgrade` (`apps/server/src/auth/EnvironmentAuth.ts:1075-1095`):
   - a non-empty `?wsTicket=` query param is verified as a signed websocket ticket. It is **not single-use**. It is
     valid for **5 minutes** (`SessionStore.ts:424`) and is rejected if the underlying session has been revoked or has expired.
   - otherwise it falls back to normal request auth (cookie / `Authorization: Bearer`). A native client that can set
     upgrade headers (URLSessionWebSocketTask with a URLRequest can) may skip the ticket.
   - on failure the upgrade is answered with HTTP 401 and the `EnvironmentAuthInvalidError` JSON above.
3. Optional client-identity query params, read leniently (`ws.ts:522-586`; client writes them in
   `packages/client-runtime/src/authorization/remote.ts:40-84`):
   `clientSurface` (web|desktop|mobile), `clientAppVersion` (≤64 chars), `clientDeviceType` (phone|tablet|desktop|unknown),
   `clientOs` (e.g. `iOS`), `clientOsMajorVersion` (mobile only), `clientDeviceModel` (mobile only, ≤80 chars),
   `connectionMethod` (`direct`|`relay`|`ssh`|…), plus `clientWebDeployment`/`clientBrowser` for web.

Ticket issuance: `POST /api/auth/websocket-ticket` with Bearer and an empty body → `{"ticket":"<b64url>.<sig>","expiresAt":"2026-10-03T12:05:00.000Z"}`
(handler `apps/server/src/auth/http.ts:386-399`; client `packages/client-runtime/src/authorization/remote.ts:161-224`).
The official client fetches a fresh ticket for every connection attempt (`authorization/service.ts:135-190`), and
before that re-validates the descriptor (cached for a TTL) to confirm the `environmentId` still matches.

Final URL built by the official client:
```
ws://100.101.102.103:3783/ws?wsTicket=eyJ2IjoxLCJraW5kIjoid2Vic29ja2V0Ii...Q.abc&clientSurface=mobile&clientAppVersion=1.2.3&clientDeviceType=phone&clientOs=iOS&clientOsMajorVersion=26&clientDeviceModel=iPhone+17+Pro&connectionMethod=direct&orchestrationProtocol=2
```
If the wsBaseUrl path is `/` or empty, it is replaced with `/ws` (`remote.ts:217-220`).

No subprotocol (`Sec-WebSocket-Protocol`) is used. The server negotiates permessage-deflate when the client offers it
(`apps/server/src/server.ts:258`).

**Handshake / hello**: the server sends nothing until it receives a request. The official client's first request is the
`subscribeServerConfig` stream. It waits for the first chunk with `type:"snapshot"` and checks that
`config.environment.environmentId` equals the expected id. It then runs a probe: `server.probe` with payload `{}` if
`capabilities.connectionProbe` is set, otherwise `server.getConfig` with `{}`
(`packages/client-runtime/src/rpc/session.ts:213-348`). The socket open timeout is 15 s (`session.ts:45`).

**Heartbeat**: this is application-level, not WS ping frames. The client sends `{"_tag":"Ping"}` every 5 s and the server
replies `{"_tag":"Pong"}` (`RpcServer.ts:799-801`). In the patched client pinger (`patches/effect@4.0.0-rc.115.patch`,
`makePinger`), a ping goes out every 5 s and the socket is declared dead after 3 consecutive intervals without a Pong
(about 15-20 s). Unpatched upstream fails after one missed interval (`RpcClient.ts:1201-1222`). The server has no idle
timeout of its own.

**Reconnect**: the per-socket protocol does not retry (`retryTransientErrors:false, retryPolicy: Schedule.recurs(0)`,
`packages/client-runtime/src/rpc/session.ts:195-206`). The connection supervisor retries with jittered exponential
backoff: `delay = ceiling/2 + random*ceiling/2` with `ceiling = min(300000, 1000 * 2^(failureCount+1))` ms, i.e.
1-2 s, 2-4 s, 4-8 s ... capped at 5 min (`packages/client-runtime/src/connection/supervisor.ts:34-35, 119-122`).
Foregrounding the app, network-up events, and an explicit retry skip the wait. Each reconnect fetches the descriptor
(when its cache has expired), mints a new ticket, opens a new socket, and re-subscribes every stream from scratch. The
server keeps no RPC state across sockets; resubscribe streams use their own cursors/sequence payloads.

Every RPC also checks scopes on the server (`apps/server/src/auth/RpcAuthorization.ts:21-...`). A missing scope arrives
as a typed failure `EnvironmentAuthorizationError {message, requiredScope}` in the Exit.

---------------------------------------------------------------------------------------------------

## 3. RPC framing on the socket

### 3.1 Serialization actually used

**`RpcSerialization.layerJson`** on both ends:
- server: `apps/server/src/ws.ts:3789-3804` (`RpcServer.makeProtocolWithHttpEffectWebsocket` + `RpcSerialization.layerJson`), `RpcServer.make(ServerWsRpcGroup, { disableTracing: true })`
- client: `packages/client-runtime/src/rpc/session.ts:192-206` (`Socket.layerWebSocket` + `RpcClient.makeProtocolSocket` + `RpcSerialization.layerJson`)

`json` serialization (`RpcSerialization.ts:122-133`):
```ts
decode: (bytes) => { const decoded = JSON.parse(text); return Array.isArray(decoded) ? decoded : [decoded] }
encode: (response) => JSON.stringify(response)
```
- Each **WebSocket text frame is one JSON value**: one message object, or a JSON array of message objects (both are
  accepted on decode). The server always writes **one message object per frame** (`RpcServer.ts:1520-1534`). It is not
  ndjson, not msgpack, and has no length prefix.
- Payload, chunk values, and exit values go through `Schema.toCodecJson` (`RpcSerialization.ts:39`), the JSON codec of
  each RPC's Effect Schema. Notable encodings, verified by running the installed effect:
  - `DateTimeUtc` → ISO string `"1970-01-01T00:00:00.000Z"`
  - `Option` → `{"_tag":"Some","value":1}` / `{"_tag":"None"}`
  - `BigInt` → decimal string `"5"`
  - `Schema.Void` → `null`
  - `Schema.TaggedError` → plain object with `_tag` plus its fields
  - optional keys are omitted when absent

### 3.2 Message shapes (source: `RpcMessage.ts`)

Client → server (`FromClientEncoded`, `RpcMessage.ts:34, 65-75, 125-161`):
```ts
{ _tag: "Request", id: string|number, tag: string, payload: unknown,
  headers: Array<[string,string]>, traceId?: string, spanId?: string, sampled?: boolean }
{ _tag: "Ack", requestId: string|number }
{ _tag: "Interrupt", requestId: string|number }
{ _tag: "Ping" }
{ _tag: "Eof" }
```
Server → client (`FromServerEncoded`, `RpcMessage.ts:197-203, 236-240, 263-293, 328-331, 409-411`):
```ts
{ _tag: "Chunk", requestId: string|number, values: [v1, v2, ...] }   // non-empty array of encoded stream items
{ _tag: "Exit",  requestId: string|number, exit: ExitEncoded }
{ _tag: "Defect", defect: unknown }                                  // connection-level fatal defect
{ _tag: "Pong" }
// ("Request" with isNotification is defined but this app's server does not send it)
```
ExitEncoded (`RpcMessage.ts:263-280`, `Schema.Exit`/`Schema.Cause` codecs at `Schema.ts:10486-10560, 12253-12330`):
```ts
{ _tag: "Success", value: A }
{ _tag: "Failure", cause: Array<
    { _tag: "Fail", error: E } |
    { _tag: "Die", defect: unknown } |
    { _tag: "Interrupt", fiberId: number | null } > }
```
`Schema.Defect` encodes `Error` values as `{"name":"Error","message":"..."}` (plus `cause` when present). Other values
pass through as JSON (`Schema.ts:8690-8742`).

**Request ids**: the official client sends **JSON numbers** from a module-global counter starting at 0
(`RpcClient.ts:211, 266`: `requestIdCounter++`). They are not stringified bigints. The server accepts either a string or
a number and echoes it back unchanged in `requestId` (`RpcServer.ts:765-777`). Ids only need to be unique among in-flight
requests on one socket; a duplicate in-flight id is ignored or interrupted (`RpcServer.ts:236-238`). A native client
can use an incrementing Int.

**Required fields**: send `headers: []` every time. The server does `upgradeHeaders.concat(message.headers)`
(`RpcServer.ts:1551-1555`), so omitting the field corrupts the headers. Send `payload: {}` for RPCs with an empty-struct
payload. `traceId`/`spanId`/`sampled` are optional. The TS client includes them, but the server runs with
`disableTracing: true` and ignores them for spans.

### 3.3 Semantics you must implement

- **Acks are required for streams.** The socket protocol has `supportsAck: true` (`RpcServer.ts:1590`,
  `RpcClient.ts:1190`). After sending each `Chunk`, the server closes a latch and **waits for the client's `Ack`
  before producing the next chunk** (`RpcServer.ts:395-446`). If you never ack, a subscription delivers one chunk and
  then stalls. The TS client acks right after enqueueing each chunk (`RpcClient.ts:563-575`).
  Exception: for `terminal.attach` and `subscribeTerminalEvents` the server self-acks while up to 8 chunks / 64 KiB are
  pending, and your Acks only shrink that window (`apps/server/src/terminal/OutputProtocol.ts:5-66`). Acking every
  chunk is still correct there.
- **Streams**: one Request → zero or more `Chunk` frames (each with `values` = an array of ≥1 items) → one `Exit`.
  The stream Exit success value is `null` (Void). A stream failure is `Exit` with `Failure`.
- **Non-stream**: one Request → one `Exit` with `Success{value}` or `Failure{cause}`.
- **Interrupt / unsubscribe**: send `{"_tag":"Interrupt","requestId":N}`. The server interrupts the handler fiber and
  usually emits a final `Exit` with an `Interrupt` cause, which you can ignore after you dropped the entry
  (`RpcServer.ts:197-209`). The TS client sends Interrupt when a stream consumer's scope closes (`RpcClient.ts:470-485`).
- **Defects**: a handler that dies (unexpected exception) does not produce an Exit for that request. The server sends a
  connection-level `{"_tag":"Defect","defect":...}` (`RpcServer.ts:299-306, 448-458`; `disableFatalDefects` is not set
  in `ws.ts:3790`). The TS client then **fails every in-flight request** with that defect (`RpcClient.ts:584-586`).
  A Die is sent per request as an `Exit` only for payload decode failures and unknown tags (`RpcServer.ts:240-251, 777-797`).
- **Unknown tag**: `Exit` → `Failure` → `[{"_tag":"Die","defect":"Unknown request tag: foo"}]`.
- **Payload schema mismatch**: `Exit` with `Die` and the schema issue text as the defect.
- **Eof**: optional. The TS client never sends it. If sent, the server ends the client after in-flight requests finish.

### 3.4 Concrete frames

Request (non-stream, empty payload):
```json
{"_tag":"Request","id":3,"tag":"server.probe","payload":{},"headers":[]}
```
Request (stream) as the official client sends it first:
```json
{"_tag":"Request","id":0,"tag":"subscribeServerConfig","payload":{"environmentThemes":true,"usageLimitSources":true},"headers":[],"traceId":"4bf92f3577b34da6a3ce929d0e0e4736","spanId":"00f067aa0ba902b7","sampled":true}
```
Streaming chunk (server → client):
```json
{"_tag":"Chunk","requestId":0,"values":[{"version":1,"type":"snapshot","config":{"environment":{"environmentId":"...","label":"MacBook","platform":{"os":"darwin","arch":"arm64"},"serverVersion":"...","orchestrationProtocolVersion":2,"capabilities":{...}}, "...":"..."}}]}
```
Ack (client → server, after each Chunk):
```json
{"_tag":"Ack","requestId":0}
```
Exit / success (non-stream):
```json
{"_tag":"Exit","requestId":3,"exit":{"_tag":"Success","value":{}}}
```
Exit / success (stream completed):
```json
{"_tag":"Exit","requestId":0,"exit":{"_tag":"Success","value":null}}
```
Exit / typed failure:
```json
{"_tag":"Exit","requestId":7,"exit":{"_tag":"Failure","cause":[{"_tag":"Fail","error":{"_tag":"EnvironmentAuthorizationError","message":"...","requiredScope":"orchestration:operate"}}]}}
```
Exit / defect (die):
```json
{"_tag":"Exit","requestId":8,"exit":{"_tag":"Failure","cause":[{"_tag":"Die","defect":{"name":"Error","message":"boom"}}]}}
```
Exit / interrupted:
```json
{"_tag":"Exit","requestId":5,"exit":{"_tag":"Failure","cause":[{"_tag":"Interrupt","fiberId":42}]}}
```
(`fiberId` may be `null`.)

Connection-level defect:
```json
{"_tag":"Defect","defect":{"name":"Error","message":"..."}}
```
Interrupt (client → server):
```json
{"_tag":"Interrupt","requestId":5}
```
Ping / Pong:
```json
{"_tag":"Ping"}
{"_tag":"Pong"}
```
Eof (optional):
```json
{"_tag":"Eof"}
```

### 3.5 Method names (for orientation)

`packages/contracts/src/rpc.ts:343-540` (`WS_METHODS`) and `packages/contracts/src/orchestrationV2.ts:2889-2900`
(`ORCHESTRATION_V2_WS_METHODS`). Core ones:
`subscribeServerConfig` (stream), `server.probe`, `server.getConfig`, `orchestration.subscribeShell` (stream),
`orchestration.subscribeThread` (stream), `orchestration.dispatchCommand`, `orchestration.getThreadProjection`,
`orchestration.searchThreads`, `orchestration.launchThread`, `orchestration.getTurnDiff`, `projects.list`,
`attachments.createUploadUrl`, `voice.transcribe` (Helm), `subscribeServerLifecycle`, `terminal.*`.
Payload/success/error schemas are in the same files (`Rpc.make(name, {payload, success, error, stream})`).
For a stream RPC the Exit success schema is Void, and the error union is the RPC error ∪ the stream error
(`effect/src/unstable/rpc/Rpc.ts:1123-1149`).

`subscribeServerConfig` event union (`packages/contracts/src/server.ts:735-803`): `{version:1,type:"snapshot",config}`,
`keybindingsUpdated`, `providerStatuses`, `settingsUpdated`, `environmentThemesUpdated` (only if you sent
`environmentThemes:true`), `usageLimitSourcesUpdated` (only if you sent `usageLimitSources:true`). Unknown event types
make the TS client's decoder fail, so leave flags out unless you handle those events.

### 3.6 Native-client gotchas

- `URLSessionWebSocketTask.maximumMessageSize` defaults to 1 MiB. Server frames (shell/thread snapshots, big chunks)
  can be larger, so raise it, e.g. to 64 MiB.
- Use `.string` messages for sending. The server's decoder accepts text or binary.
- Encode ids as JSON numbers and match `requestId` as number-or-string.
- Ack every Chunk promptly, otherwise streams stall.
- Ping every ~5 s and reconnect if no Pong arrives within ~15 s.
- Treat a `Defect` frame as "all in-flight requests failed". Resubscribe or reconnect.

---------------------------------------------------------------------------------------------------

## 4. Environment descriptor (read first, unauthenticated)

`GET /.well-known/t3/environment` (`packages/contracts/src/environmentHttp.ts:429-433`; client
`packages/client-runtime/src/environment/descriptor.ts:8-17`). Schema `ExecutionEnvironmentDescriptor`
(`packages/contracts/src/environment.ts:201-209`):
```json
{
  "environmentId": "env_...",
  "label": "My MacBook Pro",
  "platform": { "os": "darwin", "arch": "arm64", "machine": "laptop" },
  "serverVersion": "0.x.y",
  "orchestrationProtocolVersion": 2,
  "capabilities": {
    "repositoryIdentity": true,
    "connectionProbe": true,
    "attachmentUploads": true,
    "voiceTranscription": true,
    "fileAttachments": { "maxUploadBytes": 26214400 },
    "threadSettlement": true, "threadSnooze": true, "threadPinning": true, "...": "..."
  }
}
```
All capability flags are listed with comments in `environment.ts:91-198`. Missing means unsupported.
`voiceTranscription` is a Helm-fork flag (`environment.ts:96-97`).
`screenRemote` (Helm fork, experimental) means `GET /api/helm/screen?wsTicket=…` upgrades to a
WebSocket that streams the Mac's screen (`apps/server/src/helm/screenRemoteRoute.ts`,
`native/helm-screen/main.swift`; needs `terminal:operate`):
- server → phone, binary `[u8 kind][payload]`: kind 2 is SPS/PPS as `[u8 count]([u16 BE length][set])…`,
  sent before every keyframe; kind 1 is a frame as `[u8 flags, 1 = keyframe][u64 BE pts µs][AVCC, 4-byte lengths]`.
- server → phone, text JSON: `{"t":"info",width,height,videoWidth,videoHeight,accessibility}` (points),
  `{"t":"cursor",x,y}` (points from the display's top-left; the video leaves the cursor out),
  `{"t":"error",code: "screenRecording"|"accessibility"|"capture"|"noDisplay",message}`.
- phone → server, text JSON: `start {maxWidth,fps,bitrate}`, `keyframe`, `move {x,y}`,
  `button {b: left|right|middle, down, x, y}`, `scroll {dx,dy}` (pixels), `key {code, mods: [cmd|alt|ctrl|shift]}`
  (Mac virtual key codes), `text {s}`, `stop`.
- Locked session: the helper sends `lockState {locked,available,unlockEnabled}` on connection and
  whenever the lock state or desktop-local consent changes. `available:false` denies input;
  an older helper sends no lock state. `unlock {password}` is transient and answered with
  `unlockResult {status}`: `submitted` is only delivery, `unlocked` confirms session state,
  and `disabled`, `unavailable`, `notLocked`, `invalidPassword`, `accessibility`, `focusPassword`,
  `busy`, or `stillLocked` explain why the attempt did not proceed or finish. Password input targets
  loginwindow's focused secure field. Consent is desktop IPC only; ordinary input while locked
  also requires it. The connection wakes the display and holds it awake until it ends.
- Bringing a window to the iPad's display: `windows` is answered with
  `{"t":"windows",windows:[{id,pid,app,title,display}],icons:{pid: png base64}}` (the other displays' windows,
  front to back); `moveWindow {id}` moves one onto the virtual display
  (through Accessibility), answered with `{"t":"windowMoved",id}` or an error with code `moveWindow`. The display's
  keeper remembers where each window was and puts the ones still on it back as soon as the last connection
  closes; a connection that comes back while the display lingers gets them onto it again.

Compatibility rule (`packages/client-runtime/src/connection/compatibility.ts:9-27`): if
`orchestrationProtocolVersion ?? 1` is not 2, the client refuses (a server newer than the client means the client must
be updated; an older one means the server must be updated). The descriptor's `environmentId` is the stable identity
used for dedupe (`connectionId = "bearer:" + environmentId`) and must equal `config.environment.environmentId` from the
first `subscribeServerConfig` snapshot.

---------------------------------------------------------------------------------------------------

## 5. Helm fork specifics

### 5.1 Port and binding
`apps/desktop/src/app/DesktopApp.ts:37-41`: Helm desktop's backend starts at **3783** and moves up when the port is
taken (T3 Code keeps 3773). The desktop binds `0.0.0.0` only when network exposure is enabled
(`apps/desktop/src/backend/DesktopServerExposure.ts:31`). Pairing is plain `http://<tailscale-ip>:3783`; WireGuard
already encrypts the traffic, and TLS is not used on the tailnet path.

Ports the mobile app probes (`apps/mobile/helm/tailscale/autoPair.ts:20`): `[3783, 3784, 3785, 3773, 3774, 3775, 3776, 3777]`.

### 5.2 Tailnet auto-pair (Helm-only server routes)
Server: `apps/server/src/helm/tailnetPairRoute.ts` (registered in `apps/server/src/server.ts:638`). Requests are held in
memory for 5 minutes.

Phone side (unauthenticated, but the caller IP must be a Tailscale IPv4 and `tailscale whois <ip>` must return the same
UserID as the Mac's own `tailscale status --json` `Self.UserID`; otherwise **403 text "Forbidden"**, `:44-53, 204-224, 238-250`):

- `POST /api/helm/tailnet-pair`, JSON body `{"label":"<device name>"}` (optional, trimmed, max 80 chars; falls back to
  the tailnet node name) → `{"requestId":"<uuid>"}` (`:256-275`). One open request per address; asking again returns the existing one.
- `GET /api/helm/tailnet-pair?id=<requestId>` → one of (`:277-288`, `:94-107`)
  - `{"status":"pending"}`
  - `{"status":"denied"}`
  - `{"status":"expired"}` (unknown id or another address)
  - `{"status":"approved","credential":"7K3MZQ9XH2PA"}`. This is returned once and then forgotten.

Mac side (Helm UI, requires a session with `access:write`):
- `GET /api/helm/tailnet-pair-requests?after=<version>`: long-poll (25 s) → `{"version":N,"requests":[{id,label,nodeName,address,createdAt}]}`
- `POST /api/helm/tailnet-pair-requests` `{"id":"...","approve":true|false}` → `{"ok":true}`. Approving mints a
  standard one-time credential (`auth.issuePairingCredential()`, standard scopes).

Mobile flow (`apps/mobile/helm/tailscale/autoPair.ts:80-130`):
1. `findHelm`: for each port, `GET http://<ip>:<port>/api/helm/tailnet-pair?id=probe`. Helm is detected when the
   response is 200 with a `content-type` containing `json` (it returns `{"status":"expired"}`). Stock T3 Code serves its
   SPA there instead.
2. `GET /.well-known/t3/environment` → skip if the `environmentId` is already saved.
3. `POST /api/helm/tailnet-pair` `{label: Device.deviceName ?? "iPhone"}`.
4. Poll `GET ...?id=` every 2 s for up to 5 minutes.
5. On approval, call the normal pairing path with the synthetic URL `` `${base}/#token=${encodeURIComponent(credential)}` ``
   (`autoPair.ts:122-125`). From here on it is exactly section 1 (descriptor → `/oauth/token` → bearer).

There is **no other fork-specific auth**. Helm uses the same bearer/ticket mechanism as upstream.

### 5.3 In-app Tailscale routing (for context; not needed with the system Tailscale VPN)
`apps/mobile/helm/tailscale/install.ts` monkey-patches `fetch` and `WebSocket` so that any http/ws URL whose host is in
the tailnet (`100.64.0.0/10`, `fd7a:115c:a1e0::/48`, `*.ts.net`; `urls.ts:17-26`) is rewritten to
`http|ws://127.0.0.1:<localPort>` through a native userspace Tailscale node (`modules/helm-tailscale`, `native.ts`,
`forward(host, port) -> loopbackPort`). TLS URLs are not rewritten (`urls.ts:1-44`). Routing is on once the in-app node
has logged in (`routing.ts:4-15`, hostname `helm-phone`). A SwiftUI client running alongside the Tailscale VPN app can
connect to `100.x` directly. Note that the server's tailnet-pair check needs the request to arrive *from* a tailnet IP
owned by the same Tailscale user.

---------------------------------------------------------------------------------------------------

## 6. Push notification device registration (Helm → Volna core)

Config:
- Mobile (`apps/mobile/helm/push/config.ts:11-22`): `HELM_PUSH_URL` and `HELM_PUSH_TOKEN` are read at prebuild from the
  repo `.env` into `extra.helmPush = { url: "<HELM_PUSH_URL without trailing slash>/helm", token }`
  (`apps/mobile/app.config.ts:428-431`). The token ships inside the personal build.
- Server (`apps/server/src/helm/pushConfig.ts:7-30`): secret `helm-push` (`secrets/helm-push.bin`, JSON
  `{"url":"https://…","token":"…"}`) → publishes agent activity to `<url>/helm` instead of T3 Connect.

Phone → Volna core calls (`apps/mobile/helm/push/relayClient.ts:16-56`). All carry `authorization: Bearer <HELM_PUSH_TOKEN>`
and `content-type: application/json` when there is a body. Base is `<HELM_PUSH_URL>/helm`.

| Call | Method + path | Body | Response |
|---|---|---|---|
| register device | `POST /helm/v1/mobile/devices` | `RelayDeviceRegistrationRequest` | `{"ok":true}` |
| unregister | `DELETE /helm/v1/mobile/devices/:deviceId` | – | `{"ok":true}` |
| Live Activity token | `POST /helm/v1/mobile/live-activities` | `{"deviceId":"...","activityPushToken":"<hex>"}` | `{"ok":true}` |
| activity snapshot | `GET /helm/v1/mobile/agent-activity` | – | `{"aggregate": null \| {...}}` |

`RelayDeviceRegistrationRequest` (`packages/contracts/src/relay.ts:46-72`; built by
`apps/mobile/src/features/agent-awareness/registrationPayload.ts:13-52`):
```json
{
  "deviceId": "<stable per-install id>",
  "label": "My iPhone",
  "platform": "ios",
  "iosMajorVersion": 26,
  "appVersion": "1.2.3",
  "bundleId": "com.example.helm",
  "apsEnvironment": "sandbox",
  "pushToken": "<raw APNs device token hex>",
  "pushToStartToken": "<ActivityKit push-to-start token hex>",
  "preferences": {
    "liveActivitiesEnabled": true, "notificationsEnabled": true,
    "notifyOnApproval": true, "notifyOnInput": true, "notifyOnCompletion": true, "notifyOnFailure": true
  }
}
```
`iosMajorVersion` must be ≥ 18 when the platform is ios. `apsEnvironment` is `sandbox` for development-signed builds
and `production` otherwise. `pushToken` comes from `Notifications.getDevicePushTokenAsync()`, the raw APNs token
(`apps/mobile/src/features/agent-awareness/remoteRegistration.ts:286-307`).

Alert texts are sent by the core as `loc-key`/`title-loc-key` and filled from Localizable.strings on the device
(`apps/mobile/helm/push/alertStrings.ts`): `HELM_ALERT_APPROVAL`, `HELM_ALERT_INPUT`, `HELM_ALERT_DONE`,
`HELM_ALERT_FAILED`, `HELM_ALERT_MANY_WAITING`, `HELM_ALERT_MANY_DONE`, each with a single `%@` argument.
A native app must ship these keys in its own Localizable.strings.

The T3 server is not involved in device registration. It only publishes activity to the core. The phone registers
directly with the core.
