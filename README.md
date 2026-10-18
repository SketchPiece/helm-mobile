# Helm Mobile

**Your coding agents, in your pocket.** Helm Mobile is a native SwiftUI client for iPhone and iPad that
drives [Helm](https://github.com/SketchPiece/t3code), a desktop control surface for Claude Code, Codex,
Cursor and other coding agents. Start threads, answer approvals, review diffs, dictate prompts and even take
over the Mac's screen, from the couch or from across the world over Tailscale.

It speaks Helm's WebSocket protocol directly (no web view, no React Native), is built for iOS 26's
Liquid Glass, and treats the iPad as a first-class workstation with a sidebar, menu bar, keyboard shortcuts
and multiple windows.

> Helm is my fork of [T3 Code](https://github.com/pingdotgg/t3code). Helm Mobile replaces the fork's
> React Native app with a native one; it pairs with an unmodified Helm desktop install.

## Features

- **Threads with live streaming.** Agent output, tool calls and file changes stream in as they happen;
  agent work between messages folds into one readable block. Long threads load lazily and resume from the
  last event they saw instead of re-downloading a snapshot.
- **Answer the agent.** Approval and question cards, a message queue you can reorder by dragging,
  interrupt, per-thread model and settings, and a context-window meter.
- **Review changes.** Unified diffs per turn, in a sheet on iPhone and an inspector beside the thread on
  iPad (⌥⌘I).
- **New threads anywhere.** Pick a project, branch or worktree, attach photos and files, or start from the
  share sheet, the "New task" quick action, or a Shortcuts intent.
- **Voice input.** Hold the mic to talk and release to send; dictation keeps coding words in Latin script.
- **Drafts follow you.** Unsent drafts (text and attachments) sync with Helm on the Mac, per thread and per
  project.
- **Screen remote (experimental).** See and drive the Mac: HEVC at the display's frame rate, a
  trackpad or direct-touch mode, the Mac's cursor and sound, a shared clipboard, a virtual display sized to
  the iPad, and windows brought over from other displays. It can also unlock a locked Mac.
- **Mac remote.** Open a thread on the Mac, type into its composer and scroll its timeline from the phone.
- **Live Activity and widgets.** The Lock Screen and Dynamic Island show which agent is waiting on you; a
  Usage widget shows agent usage at a glance. Push alerts arrive when agents need you or finish.
- **Pairing that just works.** Scan Helm's QR code, type the AirPlay-style code shown on the Mac for
  machines found on the local network (Bonjour), or approve a request on the Mac for machines on your tailnet.
- **Built-in Tailscale.** An embedded tsnet node reaches your Macs over Tailscale without the Tailscale app.
- **iPad workstation.** Home in a sidebar beside the open thread, a ⌘K command palette, ⌘N project picker,
  menu bar commands, hardware keyboard shortcuts and threads in windows of their own.
- **Apple Watch remote.** See who needs you, approve or decline, answer questions, dictate replies, start a
  thread in a project, stop a run or settle a thread from the wrist. The watch has no connection of its own:
  it goes through Helm on the iPhone (WatchConnectivity), which wakes in the background to carry it out.
- **Several Macs.** Pair multiple computers and switch between them; each keeps its own session.
- **Polish.** The "Bakelite and lamp" palette with an amber accent, IBM Plex type, Dynamic Type, light and
  dark themes (plus themes a connected Mac publishes), English and Russian, and a built-in performance HUD.

## How it connects to Helm

```
iPhone / iPad                         Mac running Helm (desktop app or `t3` server)
┌──────────────────────┐   HTTP     ┌──────────────────────────────────────────┐
│ PairingView          │──────────▶ │ /.well-known/t3/environment  (descriptor)│
│ HelmHTTP             │            │ /oauth/token     (pairing → bearer token)│
│                      │ WebSocket  │                                          │
│ RPCConnection        │◀─────────▶ │ Effect RPC: orchestration, shell,        │
│ EnvironmentSession   │            │ threads, terminal, review, drafts        │
│ ThreadSession        │            │                                          │
│ ScreenRemote         │◀─────────▶ │ /api/helm/screen  (screen stream + input)│
└──────────┬───────────┘            └──────────────────────────────────────────┘
           │ LAN, Bonjour, or Tailscale (embedded tsnet node)
```

1. Helm on the Mac shows a pairing QR code or a short code (Settings → Connections), or a phone on the
   tailnet asks to pair and the Mac approves.
2. The app exchanges the one-time credential for a bearer token at `/oauth/token` and stores it in the
   Keychain.
3. It opens one WebSocket per Mac and speaks Effect RPC: JSON frames, an Ack after every chunk, a ping
   every 5 s, and a reconnect supervisor that resubscribes to the shell and open threads.

`docs/protocol.md` and `docs/transport.md` are the wire reference the app was built from.

## Architecture

- `Core/RPCConnection`: Effect RPC over one WebSocket.
- `Core/HelmHTTP`: environment descriptor, pairing, WebSocket tickets, Helm's tailnet pairing route.
- `Store/EnvironmentSession`: one per paired Mac. Reconnects, server config, the shell (projects and thread
  list), thread subscriptions, commands.
- `Store/ThreadSession`: one open thread. Live projection, outbox, approvals, queue, interrupt.
- `Model/`: wire types decoded leniently from JSON, the shell and thread reducers ported from T3 Code's
  client runtime (`ShellState.apply`, `ThreadProjection.apply`), and `Timeline`, which folds agent work
  between messages.
- `Tailscale/`: the in-app tsnet node (libtailscale) and `TailnetRouting`, which sends tailnet URLs through
  its loopback forwarders once the device has logged in.
- `Store/PushService`: device registration with the push relay, notification taps, the Live Activity.
- `Store/ScreenRemote` + `UI/Remote/`: the screen stream decoder and the trackpad/touch input model.
- `Shared/` + `HelmWidgets/`: the Live Activity (wire-compatible with the relay's content state) and the
  Usage widget, which reads a snapshot the app writes to the shared App Group.
- `HelmShare/` + `Shared/ShareInbox`: "Helm" in the share sheet; it hands content to the app through the App
  Group. `App/LaunchActions` routes shares, quick actions and the Shortcuts intent to New Thread.
- `UI/`: SwiftUI screens. Swift 6 with strict concurrency throughout.

## Build and run

Requirements: Xcode 26, iOS 26 SDK, [XcodeGen](https://github.com/yonaskolb/XcodeGen), and Go (only to build
libtailscale).

```sh
scripts/build-libtailscale.sh           # builds Vendor/libtailscale/Libtailscale.xcframework (gitignored, ~51 MB)
cp Local.xcconfig.example Local.xcconfig  # optional: Macs to suggest, push relay credentials
xcodegen generate                       # project.yml → HelmMobile.xcodeproj (not committed)
xcodebuild -project HelmMobile.xcodeproj -scheme HelmMobile \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -derivedDataPath build/dd build
```

- **Signing.** Set `DEVELOPMENT_TEAM` in `project.yml` and `APP_BUNDLE_ID` in `Base.xcconfig` to your own
  team and an App ID you control. The App Group (`group.com.sketchpiece.helm`) is hard-coded in the
  three `.entitlements` files, `Shared/ShareInbox.swift` and `Shared/UsageSnapshot.swift`; change it there too.
- **Push and Live Activity updates** need a push-enabled App ID: set `HELM_PUSH_ENABLED = YES` and
  `HELM_APP_ENTITLEMENTS = HelmMobile/HelmMobile.entitlements`, and put the relay URL and device token in
  `Local.xcconfig`. Without them the app runs with push off.
- **`Local.xcconfig`** (gitignored, see `Local.xcconfig.example`) can list the Macs the pairing screen
  probes, so connecting is one tap plus an approval in Helm on the Mac.
- **Simulator shortcut.** Launch with `-pairURL 'http://localhost:13773/pair#token=…'` to pair on start
  (mint a token in a Helm checkout with `node apps/server/src/bin.ts pair --base-dir "$PWD/.t3"`).

## Tests

```sh
xcodebuild … test -only-testing:HelmMobileTests      # unit tests, no server needed
TEST_RUNNER_HELM_TEST_URL=http://localhost:13773 TEST_RUNNER_HELM_TEST_TOKEN=<bearer> \
  xcodebuild … test -only-testing:HelmMobileTests    # plus live protocol tests against a dev server
xcodebuild … test -only-testing:HelmMobileUITests    # UI tour; screenshots land in /tmp/hm-ui
xcodebuild … test -only-testing:HelmMobileUITests/IPadTourTests   # on an iPad simulator; /tmp/hm-ipad
```

Watch: `xcodebuild -scheme HelmWatch -destination 'id=<watch simulator>' test` taps through sample data;
with `TEST_RUNNER_HELM_WATCH_LIVE=1` (watch paired with an iPhone simulator signed in to a scratch dev server
with a project `watch-scratch`) it starts, answers, stops and settles real threads from the watch.

UI scenarios that drive real agents are opt-in: `HELM_LIVE_TURN=<project>`, `HELM_ANSWER=1` (a thread
waiting on an approval or question), `HELM_REVIEW=1`, `HELM_QUEUE=1`. `HELM_APPEARANCE=dark` and
`HELM_LANGUAGE=ru` change the tour's look. `HELM_HISTORY=<thread title>` checks that loading older history
doesn't move the view, `HELM_QUEUE_DRAG=<thread title>` drags a queued message, and `HELM_CAMERA=1` looks
for the camera in the "+" menus. Pass them with the `TEST_RUNNER_` prefix and run them against an isolated
dev server, never a Helm install you use, and point agent turns at a scratch repository.

## Performance

Settings → Performance puts a counter on screen (frame rate, late frames, main-thread stalls).
Its Save button writes `Documents/Performance/perf-<date>.{txt,json}`: hitches with the main-thread
work in each late frame, stalls with sampled main-thread stacks, timed work (`Perf.measure`).
`scripts/perf-report.py --pull` copies them off a connected device and symbolicates the app's frames
from the dSYM (run `scripts/perf-report.py --keep-dsym` after each deploy so the dSYM is kept).

## Unlocking a locked Mac

In Helm on the Mac, enable **Settings → Connections → Unlock Mac from your phone**. Open the screen remote
on the phone or iPad, select your user and click the password field on the Mac screen, then enter your
password in the unlock panel. The password is used for one attempt and is not saved. This requires an
existing Mac session; it cannot log in after a restart or unlock FileVault.

## Localization

English is the source; Russian lives in `Localization/ru.json` (plurals as `one/few/many/other`).
After changing UI strings, build with `SWIFT_EMIT_LOC_STRINGS=YES`, then `python3 scripts/build-strings.py`
regenerates `Localizable.xcstrings` and lists anything untranslated.

## License

[MIT](LICENSE) © 2026 Andrew Lubkin. Third-party code and fonts are listed in
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
