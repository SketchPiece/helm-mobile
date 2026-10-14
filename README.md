# Helm Mobile

A native SwiftUI iPhone and iPad client for Helm (the T3 Code fork in `~/Documents/Projects/t3code`, branch `helm`).
It pairs with Helm on a Mac over Tailscale or the LAN and speaks the server's WebSocket protocol
directly. It replaces the React Native app with a native one; nothing on the Mac side changed.

## Build and run

```sh
xcodegen generate                       # project.yml → HelmMobile.xcodeproj (not committed)
xcodebuild -project HelmMobile.xcodeproj -scheme HelmMobile \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -derivedDataPath build/dd build
```

- iOS 26+, iPhone and iPad. A regular-width window (iPad) puts Home in a sidebar beside the open thread, with a
  menu bar, keyboard shortcuts and threads in windows of their own; a narrow one is the iPhone app. The bundle id comes from `APP_BUNDLE_ID` in `Base.xcconfig`
  (`com.sketchpiece.helm`, the push-enabled App ID the old React Native app used).
- Push and Live Activity updates need a push-enabled App ID: set `APP_BUNDLE_ID`, `HELM_PUSH_ENABLED = YES`
  and `HELM_APP_ENTITLEMENTS = HelmMobile/HelmMobile.entitlements`, and put the Volna core relay URL
  and device token in `Local.xcconfig` (see the example). Without them the app runs with push off.
- The built-in Tailscale node needs `Vendor/libtailscale/Libtailscale.xcframework` (gitignored, 51 MB):
  `scripts/build-libtailscale.sh` builds it (Go; it pins its toolchain).
- To the phone: `~/.claude/skills/sideshelf/scripts/ota-deploy.sh --push` from this folder.
- `Local.xcconfig` (gitignored, see `Local.xcconfig.example`) lists the Macs the pairing screen
  probes, so connecting is one tap plus an approval in Helm on the Mac.
- Simulator shortcut: launch with `-pairURL 'http://localhost:13773/pair#token=…'` to pair on start
  (mint a token in t3code with `node apps/server/src/bin.ts pair --base-dir "$PWD/.t3"`).

## Tests

```sh
xcodebuild … test -only-testing:HelmMobileTests      # unit tests, no server needed
TEST_RUNNER_HELM_TEST_URL=http://localhost:13773 TEST_RUNNER_HELM_TEST_TOKEN=<bearer> \
  xcodebuild … test -only-testing:HelmMobileTests    # plus live protocol tests against a dev server
xcodebuild … test -only-testing:HelmMobileUITests    # UI tour; screenshots land in /tmp/hm-ui
xcodebuild … test -only-testing:HelmMobileUITests/IPadTourTests   # on an iPad simulator; /tmp/hm-ipad
```

UI scenarios that drive real agents are opt-in: `HELM_LIVE_TURN=<project>`, `HELM_ANSWER=1` (a thread
waiting on an approval or question), `HELM_REVIEW=1`, `HELM_QUEUE=1`. `HELM_APPEARANCE=dark` and
`HELM_LANGUAGE=ru` change the tour's look. `HELM_HISTORY=<thread title>` checks that loading older history
doesn't move the view (the live test keeps a long sandbox thread with `HELM_KEEP_HISTORY_THREAD=1`),
`HELM_QUEUE_DRAG="Helm Mobile queue drag"` drags a queued message (the live test with `HELM_PREPARE_QUEUE=1`
sets that thread up; `HELM_CLEANUP=1` deletes both), and `HELM_CAMERA=1` looks for the camera in the "+" menus. Pass them with the `TEST_RUNNER_` prefix and run them
against an isolated dev server (t3code's `.t3`), never the live Helm. Point agent turns at a scratch
repo: agents follow the global "commit often" rule and will commit into whatever project they run in.

## Performance

Settings → Performance puts a counter on screen (frame rate, late frames, main-thread stalls).
Its Save button writes `Documents/Performance/perf-<date>.{txt,json}`: hitches with the main-thread
work in each late frame, stalls with sampled main-thread stacks, timed work (`Perf.measure`).
`scripts/perf-report.py --pull` copies them off a connected device and names the app's frames
from the dSYM (run `scripts/perf-report.py --keep-dsym` after each deploy so the dSYM is kept).

## Unlocking a locked Mac

In Helm on the Mac, enable **Settings → Connections → Unlock Mac from your phone**. Open
screen remote on the phone or iPad, select your user and click the password field on the Mac
screen, then enter your password in the unlock panel. The password is used for one attempt and is not saved.
This requires an existing Mac session; it cannot log in after a restart or unlock FileVault.

## Localization

English is the source; Russian lives in `Localization/ru.json` (plurals as `one/few/many/other`).
After changing UI strings, build with `SWIFT_EMIT_LOC_STRINGS=YES`, then `python3 scripts/build-strings.py`
regenerates `Localizable.xcstrings` and lists anything untranslated.

## How it is put together

- `Core/RPCConnection`: Effect RPC over one WebSocket. JSON frames, Ack after every chunk, Ping every 5 s.
- `Core/HelmHTTP`: descriptor, pairing (`/oauth/token`), websocket tickets, Helm's tailnet pairing route.
- `Store/EnvironmentSession`: one per paired Mac. Reconnect supervisor, server config, the shell
  (projects and thread list), thread subscriptions, commands.
- `Store/ThreadSession`: one open thread. Live projection, outbox, approvals, queue, interrupt.
- `Model/`: wire types read leniently from JSON, plus client-runtime's reducers (`ShellState.apply`,
  `ThreadProjection.apply`) and `Timeline`, which folds agent work between messages into one block.
- `Tailscale/`: the in-app tsnet node (from the RN module) and `TailnetRouting`, which points tailnet
  http/ws URLs at its loopback forwarders once this phone has logged in to it.
- `Store/PushService`: device registration with the Volna core, notification taps, the Live Activity.
- `Shared/` + `HelmWidgets/`: the Live Activity type (wire-compatible with the core's content-state) and its UI,
  and the "Usage" widget, which reads a snapshot the app writes to the `group.com.sketchpiece.helm` app group.
- `HelmShare/` + `Shared/ShareInbox`: "Helm" in the share sheet. It copies what was shared into the App Group
  (`group.com.sketchpiece.helm`) and opens the app, which starts a new thread with it.
  `App/LaunchActions` routes shares, the "New task" quick action and the Shortcuts intent to New Thread.
- `UI/`: SwiftUI screens in Helm's "Bakelite and lamp" palette with IBM Plex and Dynamic Type.

`docs/protocol.md` and `docs/transport.md` are the wire reference this was built from;
`docs/ux-audit.md` records what changed from the React Native app and why.
