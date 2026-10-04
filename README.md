# Helm Mobile

A native SwiftUI iPhone client for Helm (the T3 Code fork in `~/Documents/Projects/t3code`, branch `helm`).
It pairs with Helm on a Mac over Tailscale or the LAN and speaks the server's WebSocket protocol
directly. It replaces the React Native app with a native one; nothing on the Mac side changed.

## Build and run

```sh
xcodegen generate                       # project.yml → HelmMobile.xcodeproj (not committed)
xcodebuild -project HelmMobile.xcodeproj -scheme HelmMobile \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -derivedDataPath build/dd build
```

- iOS 26+, iPhone only, bundle id `com.sketchpiece.helmnative`, so it installs next to the old app.
- Signing: team `4KSA86792T`; the Xcode-managed wildcard profile covers it (no extra capabilities).
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
```

UI scenarios that drive real agents are opt-in: `HELM_LIVE_TURN=<project>`, `HELM_ANSWER=1` (a thread
waiting on an approval or question), `HELM_REVIEW=1`, `HELM_QUEUE=1`. `HELM_APPEARANCE=dark` and
`HELM_LANGUAGE=ru` change the tour's look. Pass them with the `TEST_RUNNER_` prefix and run them
against an isolated dev server (t3code's `.t3`), never the live Helm. Point agent turns at a scratch
repo: agents follow the global "commit often" rule and will commit into whatever project they run in.

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
- `UI/`: SwiftUI screens in Helm's "Bakelite and lamp" palette with IBM Plex and Dynamic Type.

`docs/protocol.md` and `docs/transport.md` are the wire reference this was built from;
`docs/ux-audit.md` records what changed from the React Native app and why.
