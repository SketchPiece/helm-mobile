#!/usr/bin/env bun
// A stand-in Helm server with invented projects and threads, for screenshots and UI work
// without a real Mac session. It speaks just enough of the protocol (docs/protocol.md) for
// Home, threads, approvals, questions, diffs and the screen remote to render.
//
//   bun scripts/demo-server.ts [--port 13999] [--screen path/to/frame.h264]
//   app launch argument: -pairURL 'http://localhost:13999/pair#token=demo'
//
// Commands are acknowledged and ignored; nothing changes after the first snapshot.

import { readFileSync } from "node:fs";

const args = process.argv.slice(2);
const option = (name: string) => {
  const index = args.indexOf(name);
  return index >= 0 ? args[index + 1] : undefined;
};
const port = Number(option("--port") ?? 13999);
const screenFile = option("--screen");

const environmentId = "demo-mac-studio";
const now = Date.now();
const ago = (minutes: number) => new Date(now - minutes * 60_000).toISOString();
const later = (minutes: number) => new Date(now + minutes * 60_000).toISOString();

// MARK: Projects

const root = "/Users/demo/Code";
const projects = [
  { id: "p-fieldnotes", title: "Fieldnotes", icon: { kind: "monogram", text: "FN", color: "amber" } },
  { id: "p-harbor", title: "harbor-api", icon: { kind: "monogram", text: "HA", color: "blue" } },
  { id: "p-tidewatch", title: "Tidewatch", icon: { kind: "monogram", text: "TW", color: "teal" } },
  { id: "p-site", title: "website", icon: { kind: "emoji", emoji: "🌐" } },
].map((p) => ({
  id: p.id,
  title: p.title,
  workspaceRoot: `${root}/${p.title.toLowerCase()}`,
  projectIcon: p.icon,
  createdAt: ago(60 * 24 * 40),
  updatedAt: ago(30),
  repositoryIdentity: { displayName: `demo/${p.title.toLowerCase()}` },
}));

const opus = { instanceId: "claudeAgent", model: "claude-opus-5-5", options: [{ id: "effort", value: "high" }] };
const gpt = { instanceId: "codex", model: "gpt-6.1", options: [{ id: "effort", value: "medium" }] };

// MARK: Thread list

type ThreadSeed = {
  id: string;
  projectId: string;
  title: string;
  minutes: number;
  model?: typeof opus;
  status?: string;
  running?: boolean;
  pending?: "permission" | "user_input";
  latest?: string;
  role?: string;
  done?: boolean;
  error?: string;
  pinned?: boolean;
  snoozeMinutes?: number;
  settled?: boolean;
  branch?: string;
  pr?: number;
};

const seeds: ThreadSeed[] = [
  { id: "t-approval", projectId: "p-fieldnotes", title: "Snapshot tests for the new entry header", minutes: 1,
    running: true, pending: "permission", latest: "The header renders correctly in the previews. I'll run the snapshot suite to confirm." },
  { id: "t-question", projectId: "p-tidewatch", title: "Tide chart on the Lock Screen widget", minutes: 3, model: gpt,
    pending: "user_input", status: "running", running: true, latest: "Should the widget draw the next 12 hours or the whole day?" },
  { id: "t-working", projectId: "p-harbor", title: "Rate-limit the upload endpoint", minutes: 0.3,
    running: true, latest: "Adding a token bucket per API key in middleware/ratelimit.go", branch: "rate-limit-uploads" },
  { id: "t-site", projectId: "p-site", title: "Dark mode for the docs pages", minutes: 2, model: gpt,
    running: true, latest: "Moving the hard-coded colors in docs.css to CSS variables" },
  { id: "t-done", projectId: "p-fieldnotes", title: "Fix the flaky sync test", minutes: 12, done: true,
    latest: "Fixed. The test now waits for the sync queue to drain instead of sleeping for two seconds.", branch: "fix-sync-test", pr: 214 },
  { id: "t-failed", projectId: "p-harbor", title: "Upgrade to Postgres 18", minutes: 38, status: "failed",
    error: "Migration 0042 failed: column \"archived_at\" already exists" },
  { id: "t-pinned", projectId: "p-fieldnotes", title: "Release checklist for 2.4", minutes: 60 * 5, pinned: true,
    latest: "Everything on the list is done except the App Store screenshots." },
  { id: "t-idle1", projectId: "p-tidewatch", title: "Search tide stations by name", minutes: 60 * 3,
    latest: "Search now matches station names and nearby towns, with results sorted by distance." },
  { id: "t-idle2", projectId: "p-harbor", title: "OpenAPI spec for the v2 endpoints", minutes: 60 * 26,
    latest: "The spec validates and the generated client compiles." },
  { id: "t-snoozed", projectId: "p-fieldnotes", title: "Investigate memory spike on launch", minutes: 60 * 8,
    snoozeMinutes: 60 * 16, latest: "Instruments points at thumbnail decoding. I'll look again with a larger library." },
  { id: "t-settled1", projectId: "p-site", title: "Compress hero images", minutes: 60 * 30, settled: true, latest: "Saved 1.8 MB on the home page." },
  { id: "t-settled2", projectId: "p-tidewatch", title: "Localize units for the UK", minutes: 60 * 50, settled: true, latest: "Heights show in metres and feet by region." },
];

function threadJSON(s: ThreadSeed) {
  const running = s.running ?? false;
  return {
    id: s.id,
    projectId: s.projectId,
    title: s.title,
    modelSelection: s.model ?? opus,
    runtimeMode: s.pending === "permission" ? "approval-required" : "auto-accept-edits",
    interactionMode: "default",
    branch: s.branch ?? null,
    worktreePath: null,
    status: s.status ?? (running ? "running" : "idle"),
    activityRunStatus: running ? "running" : null,
    activityRunStartedAt: running ? ago(s.minutes + 3) : null,
    lastError: s.error ?? null,
    lastErrorClass: s.error ? "provider" : null,
    pendingRuntimeRequest: s.pending ? { kind: s.pending } : null,
    latestVisibleMessage: s.latest ? { text: s.latest, role: s.role ?? "assistant" } : null,
    hasActionableProposedPlan: false,
    createdAt: ago(s.minutes + 40),
    updatedAt: ago(s.minutes),
    latestRunId: `${s.id}-run2`,
    latestRunCompletedAt: running ? null : ago(s.minutes),
    lastVisitedAt: s.done ? ago(s.minutes + 20) : ago(Math.max(0, s.minutes - 1)),
    settledOverride: s.settled ? "settled" : null,
    settledAt: s.settled ? ago(s.minutes - 10) : null,
    snoozedUntil: s.snoozeMinutes ? later(s.snoozeMinutes) : null,
    snoozedAt: s.snoozeMinutes ? ago(s.minutes - 5) : null,
    pinnedAt: s.pinned ? ago(60 * 24 * 3) : null,
    pinOrderKey: s.pinned ? "a0" : null,
    activeOrderKey: null,
    branchPullRequest: s.pr ? { number: s.pr, state: "open" } : null,
    pendingBackgroundTasks: [],
    lineage: {},
  };
}

const threads = seeds.map(threadJSON);

// MARK: Thread detail

let ordinal = 0;
function item(threadId: string, runId: string, type: string, minutesAgo: number, fields: Record<string, unknown> = {}, id?: string) {
  ordinal += 1;
  const status = (fields.status as string) ?? "completed";
  return {
    id: id ?? `${threadId}-item-${ordinal}`,
    type,
    threadId,
    runId,
    ordinal,
    status,
    startedAt: ago(minutesAgo),
    completedAt: status === "completed" ? ago(Math.max(0, minutesAgo - 0.2)) : null,
    ...fields,
  };
}

function run(threadId: string, n: number, startedMinutes: number, endedMinutes: number | null, checkpointId?: string) {
  return {
    id: `${threadId}-run${n}`,
    ordinal: n,
    status: endedMinutes === null ? "running" : "completed",
    userMessageId: `${threadId}-msg${n}`,
    providerThreadId: `${threadId}-pt`,
    requestedAt: ago(startedMinutes),
    startedAt: ago(startedMinutes),
    workStartedAt: ago(startedMinutes),
    completedAt: endedMinutes === null ? null : ago(endedMinutes),
    checkpointId: checkpointId ?? null,
  };
}

const user = (t: string, r: string, m: number, text: string) => item(t, r, "user_message", m, { text });
const say = (t: string, r: string, m: number, text: string, extra: Record<string, unknown> = {}) =>
  item(t, r, "assistant_message", m, { text, ...extra });
const think = (t: string, r: string, m: number, text: string, extra: Record<string, unknown> = {}) =>
  item(t, r, "reasoning", m, { text, ...extra });
const cmd = (t: string, r: string, m: number, input: string, extra: Record<string, unknown> = {}) =>
  item(t, r, "command_execution", m, { input, exitCode: 0, ...extra });
const edit = (t: string, r: string, m: number, path: string, additions: number, deletions: number) =>
  item(t, r, "file_change", m, { fileName: path, additions, deletions, changes: [{ path }] });
const search = (t: string, r: string, m: number, pattern: string, files: string[]) =>
  item(t, r, "file_search", m, { pattern, results: files.map((fileName) => ({ fileName })) });

type Detail = { items: any[]; runs: any[]; requests?: any[]; checkpoints?: any[]; diff?: string; usage?: [number, number] };
const details: Record<string, Detail> = {};

{
  const t = "t-working", r1 = `${t}-run1`, r2 = `${t}-run2`;
  details[t] = {
    runs: [run(t, 1, 34, 27, "cp-working-1"), run(t, 2, 6, null)],
    items: [
      user(t, r1, 34, "Uploads from one bad client took the API down last night. Add per-key rate limiting to POST /v1/uploads, 20 a minute with a small burst, and return a proper 429."),
      say(t, r1, 33, "I'll look at how requests reach the upload handler first."),
      search(t, r1, 33, "uploads", ["internal/http/routes.go", "internal/http/uploads.go", "internal/http/middleware/auth.go"]),
      think(t, r1, 32, "**The API key is resolved in the auth middleware**, so the limiter can sit right after it and key on it."),
      edit(t, r1, 30, "internal/http/middleware/ratelimit.go", 30, 0),
      edit(t, r1, 29, "internal/http/routes.go", 6, 2),
      cmd(t, r1, 28, "go test ./internal/http/..."),
      item(t, r1, "checkpoint", 27, { checkpointId: "cp-working-1", files: [
        { path: "internal/http/middleware/ratelimit.go", kind: "added", additions: 30, deletions: 0 },
        { path: "internal/http/routes.go", kind: "modified", additions: 6, deletions: 2 },
      ] }),
      say(t, r1, 27, "Added a token-bucket limiter keyed on the API key: **20 requests a minute, bursts of 5**. Requests over the limit get `429 Too Many Requests` with a `Retry-After` header. Tests pass."),
      user(t, r2, 6, "Nice. The limit should come from config so ops can change it without a deploy, and add a test that hits the limit."),
      think(t, r2, 5, "Config lives in `internal/config/config.go`, loaded from env with defaults."),
      edit(t, r2, 4, "internal/config/config.go", 12, 1),
      edit(t, r2, 3, "internal/http/middleware/ratelimit.go", 9, 4),
      edit(t, r2, 2, "internal/http/middleware/ratelimit_test.go", 58, 0),
      item(t, r2, "todo_list", 1.5, { steps: [
        { text: "Read the limit from UPLOAD_RATE_PER_MINUTE", status: "completed" },
        { text: "Pass the config into the middleware", status: "completed" },
        { text: "Test: the 21st request in a minute gets a 429", status: "running" },
        { text: "Document the variable in README", status: "pending" },
      ] }),
      cmd(t, r2, 0.4, "go test ./internal/http/middleware -run TestUploadRateLimit -v", { status: "running", exitCode: null }),
    ],
    checkpoints: [{ id: "cp-working-1", runId: r1, appRunOrdinal: 1, status: "ready", files: [
      { path: "internal/http/middleware/ratelimit.go", kind: "added", additions: 30, deletions: 0 },
      { path: "internal/http/routes.go", kind: "modified", additions: 6, deletions: 2 },
    ] }],
    usage: [61_000, 200_000],
    diff: `diff --git a/internal/http/routes.go b/internal/http/routes.go
--- a/internal/http/routes.go
+++ b/internal/http/routes.go
@@ -18,8 +18,12 @@ func Routes(cfg config.Config, store *storage.Store) http.Handler {
 	r := chi.NewRouter()
 	r.Use(middleware.RequestID, middleware.Logger)
 	r.Use(auth.APIKey(store))

-	r.Post("/v1/uploads", uploads.Create(store))
-	r.Get("/v1/uploads/{id}", uploads.Get(store))
+	limiter := ratelimit.New(ratelimit.Options{PerMinute: 20, Burst: 5})
+	r.Group(func(r chi.Router) {
+		r.Use(limiter.Middleware)
+		r.Post("/v1/uploads", uploads.Create(store))
+	})
+	r.Get("/v1/uploads/{id}", uploads.Get(store))
 	return r
 }
diff --git a/internal/http/middleware/ratelimit.go b/internal/http/middleware/ratelimit.go
new file mode 100644
--- /dev/null
+++ b/internal/http/middleware/ratelimit.go
@@ -0,0 +1,30 @@
+package ratelimit
+
+import (
+	"net/http"
+	"strconv"
+	"sync"
+
+	"golang.org/x/time/rate"
+)
+
+// Limiter keeps one token bucket per API key.
+type Limiter struct {
+	mu      sync.Mutex
+	buckets map[string]*rate.Limiter
+	opts    Options
+}
+
+func (l *Limiter) Middleware(next http.Handler) http.Handler {
+	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
+		key := auth.KeyFrom(r.Context())
+		bucket := l.bucket(key)
+		if !bucket.Allow() {
+			retry := bucket.Reserve().Delay()
+			w.Header().Set("Retry-After", strconv.Itoa(int(retry.Seconds())+1))
+			http.Error(w, "rate limit exceeded", http.StatusTooManyRequests)
+			return
+		}
+		next.ServeHTTP(w, r)
+	})
+}
`,
  };
}

{
  const t = "t-approval", r1 = `${t}-run1`, r2 = `${t}-run2`;
  const toolId = "toolu_snapshots";
  details[t] = {
    runs: [run(t, 1, 50, 41), run(t, 2, 5, null)],
    items: [
      user(t, r1, 50, "The entry header looks cramped with long titles. Let it wrap to two lines and move the date under it."),
      think(t, r1, 49, "The header is `EntryHeaderView`; the date sits in an HStack next to the title."),
      edit(t, r1, 46, "Fieldnotes/Entries/EntryHeaderView.swift", 18, 11),
      cmd(t, r1, 43, "xcodebuild -scheme Fieldnotes build"),
      say(t, r1, 41, "The title now wraps to two lines and the date moved underneath it in the secondary style."),
      user(t, r2, 5, "Run the snapshot tests so we know nothing else moved."),
      say(t, r2, 4, "The header renders correctly in the previews. I'll run the snapshot suite to confirm."),
      cmd(t, r2, 1, "xcodebuild test -scheme Fieldnotes -only-testing:FieldnotesSnapshotTests -destination 'platform=iOS Simulator,name=iPhone 17'",
        { status: "pending", exitCode: null }, `${t}-native-item:${toolId}`),
      item(t, r2, "approval_request", 1, { requestId: `${t}-native-request:${toolId}:1`, requestKind: "command", prompt: "Run the snapshot tests?" }),
    ],
    requests: [{ id: `${t}-native-request:${toolId}:1`, kind: "permission", status: "pending", responseCapability: { type: "live" }, createdAt: ago(1) }],
    usage: [38_000, 200_000],
  };
}

{
  const t = "t-question", r1 = `${t}-run1`;
  details[t] = {
    runs: [run(t, 1, 9, null)],
    items: [
      user(t, r1, 9, "Add a Lock Screen widget that shows the tide curve for the saved station."),
      search(t, r1, 8, "TideCurve", ["Tidewatch/Charts/TideCurveView.swift", "TidewatchWidgets/NextTideWidget.swift"]),
      think(t, r1, 7, "The rectangular accessory family has room for a small curve. How much of the day it shows is a product call."),
      item(t, r1, "user_input_request", 3, { requestId: `${t}-q1`, questions: [{
        id: "range", header: "Range", question: "Should the widget draw the next 12 hours or the whole day?",
        options: [
          { label: "Next 12 hours", description: "Larger curve, always shows the next high and low" },
          { label: "Whole day", description: "Midnight to midnight, with a marker for now" },
        ],
        multiSelect: false, allowCustomAnswer: true,
      }] }),
    ],
    requests: [{ id: `${t}-q1`, kind: "user_input", status: "pending", responseCapability: { type: "live" }, createdAt: ago(3) }],
  };
}

{
  const t = "t-done", r2 = `${t}-run2`;
  details[t] = {
    runs: [run(t, 2, 26, 12, "cp-done")],
    items: [
      user(t, r2, 26, "SyncEngineTests.testOfflineEditsUpload fails about one run in five on CI. Find out why and fix it."),
      cmd(t, r2, 25, "swift test --filter SyncEngineTests --parallel --num-workers 8"),
      think(t, r2, 22, "It sleeps for two seconds and then checks the server. On a busy CI machine the upload hasn't finished yet."),
      edit(t, r2, 18, "Tests/SyncTests/SyncEngineTests.swift", 4, 1),
      edit(t, r2, 17, "Sources/Sync/SyncQueue.swift", 15, 0),
      cmd(t, r2, 14, "for i in $(seq 50); do swift test --filter SyncEngineTests || break; done"),
      item(t, r2, "checkpoint", 12, { checkpointId: "cp-done", files: [
        { path: "Tests/SyncTests/SyncEngineTests.swift", kind: "modified", additions: 4, deletions: 1 },
        { path: "Sources/Sync/SyncQueue.swift", kind: "modified", additions: 15, deletions: 0 },
      ] }),
      say(t, r2, 12, "Fixed. The test now waits for the sync queue to drain instead of sleeping for two seconds.\n\n- Added `SyncQueue.waitUntilIdle()`, which resumes once nothing is pending or in flight.\n- The test awaits it with a 10 s timeout, so a real hang still fails.\n\nIt passed 50 runs in a row with 8 workers."),
    ],
    checkpoints: [{ id: "cp-done", runId: r2, appRunOrdinal: 2, status: "ready", files: [
      { path: "Tests/SyncTests/SyncEngineTests.swift", kind: "modified", additions: 4, deletions: 1 },
      { path: "Sources/Sync/SyncQueue.swift", kind: "modified", additions: 15, deletions: 0 },
    ] }],
    diff: `diff --git a/Sources/Sync/SyncQueue.swift b/Sources/Sync/SyncQueue.swift
--- a/Sources/Sync/SyncQueue.swift
+++ b/Sources/Sync/SyncQueue.swift
@@ -41,5 +41,20 @@ actor SyncQueue {
     func markUploaded(_ change: Change) {
         inFlight = nil
         pending.removeAll { $0.id == change.id }
+        notifyIfIdle()
+    }
+
+    /// Resumes once nothing is pending or in flight.
+    func waitUntilIdle() async {
+        guard !pending.isEmpty || inFlight != nil else { return }
+        await withCheckedContinuation { idleWaiters.append($0) }
+    }
+
+    private var idleWaiters: [CheckedContinuation<Void, Never>] = []
+
+    private func notifyIfIdle() {
+        guard pending.isEmpty, inFlight == nil else { return }
+        idleWaiters.forEach { $0.resume() }
+        idleWaiters.removeAll()
     }
 }
diff --git a/Tests/SyncTests/SyncEngineTests.swift b/Tests/SyncTests/SyncEngineTests.swift
--- a/Tests/SyncTests/SyncEngineTests.swift
+++ b/Tests/SyncTests/SyncEngineTests.swift
@@ -88,7 +88,10 @@ final class SyncEngineTests: XCTestCase {
         engine.goOffline()
         try await engine.save(Entry(title: "Ridge walk", body: "Fog until noon."))
         engine.goOnline()
-        try await Task.sleep(for: .seconds(2))
+        try await withTimeout(.seconds(10)) {
+            await engine.queue.waitUntilIdle()
+        }
         let uploaded = await server.entries
         XCTAssertEqual(uploaded.count, 1)
+        XCTAssertEqual(uploaded.first?.title, "Ridge walk")
     }
`,
  };
}

function projection(threadId: string) {
  const thread = threads.find((t) => t.id === threadId)!;
  const d = details[threadId] ?? {
    runs: [run(threadId, 1, 40, 30)],
    items: [
      user(threadId, `${threadId}-run1`, 40, thread.title),
      ...(thread.latestVisibleMessage ? [say(threadId, `${threadId}-run1`, 30, thread.latestVisibleMessage.text)] : []),
    ],
  };
  return {
    kind: "snapshot",
    snapshotSequence: 100,
    projection: {
      thread: { ...thread, activeProviderThreadId: `${threadId}-pt` },
      runs: d.runs,
      attempts: [],
      runtimeRequests: d.requests ?? [],
      providerSessions: [{ id: `${threadId}-ps`, status: "ready", capabilities: { turns: { supportsActiveSteering: true, supportsQueuedMessages: true, supportsInterrupt: true } } }],
      providerThreads: [{ id: `${threadId}-pt`, providerSessionId: `${threadId}-ps`, contextUsage: d.usage ? { usedTokens: d.usage[0], maxTokens: d.usage[1] } : null }],
      checkpoints: d.checkpoints ?? [],
      messages: [],
      turnItems: d.items,
      visibleTurnItems: d.items.map((i) => ({ visibility: "local", item: i, sourceThreadId: threadId, sourceItemId: i.id })),
    },
    hasMoreHistory: false,
  };
}

// MARK: Server config

const model = (slug: string, name: string, shortName: string, isDefault = false) => ({
  slug, name, shortName, isDefault,
  capabilities: { optionDescriptors: [{ id: "effort", label: "Effort", type: "select", options: [
    { id: "low", label: "Low" }, { id: "medium", label: "Medium" }, { id: "high", label: "High", isDefault: true },
  ] }] },
});

const config = {
  environment: {
    environmentId,
    label: "Mac Studio",
    serverVersion: "0.1.1",
    capabilities: { screenRemote: true, attachmentUploads: true, fileAttachments: { maxUploadBytes: 20_000_000 }, inlineMessageContext: true },
  },
  providers: [
    { instanceId: "claudeAgent", driver: "claudeAgent", displayName: "Claude", enabled: true, installed: true, status: "ready",
      models: [model("claude-opus-5-5", "Claude Opus 5.5", "Opus 5.5", true), model("claude-sonnet-5", "Claude Sonnet 5", "Sonnet 5")] },
    { instanceId: "codex", driver: "codex", displayName: "Codex", enabled: true, installed: true, status: "ready",
      models: [model("gpt-6.1", "GPT-6.1", "GPT-6.1", true)] },
  ],
  settings: { defaultModelSelection: opus, defaultRuntimeMode: "auto-accept-edits", defaultThreadEnvMode: "local" },
  scratchWorkspaceRoot: `${root}/scratch`,
  newProjectsRoot: root,
};

const backgroundPolicy = {
  leases: [{
    clientKind: "desktop-renderer", visible: true, focused: true, recentlyInteracted: true,
    expiresAt: later(60), updatedAt: ago(0.2),
    scopes: [{ type: "thread", threadId: "t-working", composerHasContent: false }],
  }],
  hostPower: { stale: false, idle: "false", locked: "false", suspended: false },
};

// MARK: RPC

type Socket = { send: (data: string | Uint8Array) => void };

function chunk(ws: Socket, requestId: unknown, ...values: unknown[]) {
  ws.send(JSON.stringify({ _tag: "Chunk", requestId, values }));
}
function exit(ws: Socket, requestId: unknown, value: unknown = null) {
  ws.send(JSON.stringify({ _tag: "Exit", requestId, exit: { _tag: "Success", value } }));
}
function fail(ws: Socket, requestId: unknown, message: string) {
  ws.send(JSON.stringify({ _tag: "Exit", requestId, exit: { _tag: "Failure", cause: [{ _tag: "Fail", error: { _tag: "DemoUnsupported", message } }] } }));
}

let sequence = 100;

function handleRequest(ws: Socket, message: any) {
  const { id, tag, payload } = message;
  switch (tag) {
    case "subscribeServerConfig":
      return chunk(ws, id, { type: "snapshot", config });
    case "orchestration.subscribeShell":
      return chunk(ws, id, { kind: "snapshot", snapshot: { snapshotSequence: 100, projects, threads } }, { kind: "synchronized" });
    case "orchestration.subscribeThread":
      return chunk(ws, id, projection(payload.threadId));
    case "subscribeBackgroundPolicy":
      return chunk(ws, id, backgroundPolicy);
    case "helm.subscribe":
    case "subscribeServerLifecycle":
    case "subscribeProjectClones":
    case "orchestration.subscribeArchivedShell":
      return; // open and quiet
    case "orchestration.getArchivedShellSnapshot":
      return exit(ws, id, { snapshotSequence: 100, projects, threads: [] });
    case "orchestration.getTurnDiff":
      return exit(ws, id, { threadId: payload.threadId, fromTurnCount: payload.fromTurnCount, toTurnCount: payload.toTurnCount,
        diff: details[payload.threadId]?.diff ?? "" });
    case "orchestration.dispatchCommand":
      sequence += 1;
      return exit(ws, id, { sequence });
    case "server.probe":
      return exit(ws, id, {});
    case "server.getConfig":
      return exit(ws, id, config);
    case "server.refreshProviders":
      return exit(ws, id, { providers: config.providers });
    default:
      return fail(ws, id, `${tag} is not part of the demo`);
  }
}

// MARK: Screen remote

// `--screen file.h264`: an Annex B H.264 stream (one keyframe is enough), e.g.
//   ffmpeg -loop 1 -i desktop.png -frames:v 1 -c:v libx264 -profile:v high -pix_fmt yuv420p -bsf:v h264_mp4toannexb -f h264 frame.h264
function screenMessages(): { info: object; format: Uint8Array; frame: Uint8Array } | null {
  if (!screenFile) return null;
  const bytes = new Uint8Array(readFileSync(screenFile));
  const nals: Uint8Array[] = [];
  let start = -1;
  for (let i = 0; i + 3 <= bytes.length; i++) {
    const three = bytes[i] === 0 && bytes[i + 1] === 0 && bytes[i + 2] === 1;
    if (!three) continue;
    if (start >= 0) {
      let end = i;
      if (end > start && bytes[end - 1] === 0) end -= 1;
      nals.push(bytes.slice(start, end));
    }
    start = i + 3;
    i += 2;
  }
  if (start >= 0) nals.push(bytes.slice(start));
  const type = (n: Uint8Array) => n[0] & 0x1f;
  const sets = nals.filter((n) => type(n) === 7 || type(n) === 8);
  const picture = nals.filter((n) => type(n) === 5 || type(n) === 1 || type(n) === 6);
  const format = new Uint8Array(2 + sets.reduce((sum, s) => sum + 2 + s.length, 0));
  format[0] = 2;
  format[1] = sets.length;
  let offset = 2;
  for (const s of sets) {
    format[offset] = s.length >> 8;
    format[offset + 1] = s.length & 0xff;
    format.set(s, offset + 2);
    offset += 2 + s.length;
  }
  const frame = new Uint8Array(1 + 9 + picture.reduce((sum, n) => sum + 4 + n.length, 0));
  frame[0] = 1;
  offset = 10;
  for (const n of picture) {
    new DataView(frame.buffer).setUint32(offset, n.length);
    frame.set(n, offset + 4);
    offset += 4 + n.length;
  }
  const width = Number(option("--screen-width") ?? 1512);
  const height = Number(option("--screen-height") ?? 982);
  return { info: { t: "info", width, height, display: 1, accessibility: true }, format, frame };
}
const screen = screenMessages();

// MARK: HTTP

Bun.serve({
  port,
  hostname: "127.0.0.1",
  fetch(req, server) {
    const url = new URL(req.url);
    switch (url.pathname) {
      case "/.well-known/t3/environment":
        return Response.json({ environmentId, label: "Mac Studio", serverVersion: "0.1.1", orchestrationProtocolVersion: 2 });
      case "/oauth/token":
        return Response.json({ access_token: "demo-token", token_type: "Bearer", expires_in: 2_592_000 });
      case "/api/auth/websocket-ticket":
        return Response.json({ ticket: "demo-ticket", expiresAt: later(5) });
      case "/api/auth/session":
        return Response.json({ authenticated: true });
      case "/ws":
        return server.upgrade(req, { data: { kind: "rpc" } }) ? undefined : new Response("upgrade failed", { status: 400 });
      case "/api/helm/screen":
        if (!screen) return new Response("no screen", { status: 501 });
        return server.upgrade(req, { data: { kind: "screen" } }) ? undefined : new Response("upgrade failed", { status: 400 });
      default:
        return new Response("not found", { status: 404 });
    }
  },
  websocket: {
    message(ws, raw) {
      const data = ws.data as { kind: string };
      const text = typeof raw === "string" ? raw : new TextDecoder().decode(raw);
      if (data.kind === "screen") {
        const message = JSON.parse(text);
        if ((message.t === "start" || message.t === "keyframe") && screen) {
          ws.send(JSON.stringify(screen.info));
          ws.send(JSON.stringify({ t: "cursor", x: 690, y: 420 }));
          ws.send(screen.format);
          ws.send(screen.frame);
        }
        return;
      }
      const parsed = JSON.parse(text);
      for (const message of Array.isArray(parsed) ? parsed : [parsed]) {
        if (message._tag === "Ping") ws.send(JSON.stringify({ _tag: "Pong" }));
        else if (message._tag === "Request") handleRequest(ws, message);
      }
    },
  },
});

console.log(`Demo Helm server on http://localhost:${port}  (pair: http://localhost:${port}/pair#token=demo)`);
