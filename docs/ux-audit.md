# UX audit: from the React Native app to native

The React Native app (t3code `apps/mobile`, Helm layer in `apps/mobile/helm`) was audited screen by
screen before the native app was designed. The approved Helm canvases (`helm-brand`, `helm-mobile-ux`,
`helm-voice`, `mobile-thread-list`) set the look; this records what was kept, what was fixed, and what
was left out of the first version.

## What was wrong, and what the native app does instead

| Problem in the RN app | Native app |
|---|---|
| Settings → Notifications was unreachable in Helm (only the Clerk-configured settings showed it). | No dead ends: settings show only what works. Push is not in v0.1 (see below), so there is no toggle that does nothing. |
| "About T3 Code", "T3 Account", "Allow T3 Code to…" permission texts. | Helm everywhere; the name under the icon is Helm / Штурвал by phone language. |
| Typed `*.ts.net` names got `https://` and failed over the tunnel. | Bare tailnet names, IPs and `.local` get `http://` and Helm's port 3783. |
| Auto-pairing only ran while the Tailscale screen was open; a timeout read as "denied". | The pairing screen itself finds Helm on the owner's Macs and asks for approval; timeout and denial have different messages. |
| An in-app Tailscale node and a global fetch/WebSocket monkeypatch. | Uses the phone's Tailscale VPN (already required by Sideshelf). No tunnel code. |
| Thread list: project repeated on every row, empty third lines, status as a small word. | Project tile with a status lamp; one line of context only when there is something to say; "Needs you" section on top; project chips filter. |
| Several "Show more" patterns in one list. | Snoozed and settled are collapsible sections; settled loads more as you scroll. |
| Composer glass over text was hard to read. | Opaque raised panels for everything that floats over the conversation. |
| Tool calls as a long log between messages. | Agent work between two messages folds into one line ("3 commands · 2 edits"); live work shows the current step; tap to expand. |
| Approval card showed the agent's description, not the command. | The command itself, in a code block, with the description above it. |
| Questions repeated the option label as its description. | Descriptions only when they add something. |
| Archive was a one-way door from the list. | Settings → Archived threads, with Restore. |
| Sheet close buttons in the accent colour competed with real actions. | Amber is only for the primary action (send, allow, implement); chrome is neutral. |
| An in-app text-size slider. | Dynamic Type; the app follows the phone's setting. |

## Kept from the approved designs

- Bakelite/ivory palette, IBM Plex Sans/Mono, mono caps section labels, the Helm mark.
- Approval card with one prominent Allow, and Allow for session / Decline beneath it.
- Question card with options, a free-text answer and "Send answers".
- New thread: "What are we doing in <project>?", workspace chip, model chip in the composer.
- Voice: the mic sits where send goes when the field is empty. Hold to talk and release to send;
  slide left to cancel; tap for hands-free dictation that lands in the field; a failed
  transcription keeps the recording for Retry. Transcription runs on the Mac (`voice.transcribe`),
  with Apple's on-device recogniser as a fallback for servers without it.

## Not ported yet

- **Git, project files, comments on diff lines, terminal.** Next stage of work with code from the phone.
- **Server settings** (defaults for new threads, source control, agent behaviour, maintenance, provider
  accounts, server-side thread behaviour). Change them in Helm on the Mac for now.
- **Device preview** (the streamed simulator/device screen from the RN app). Planned.
- **iPad layout, hardware-keyboard shortcuts and the command palette.** Out of scope for now.
