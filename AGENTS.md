# Notes for agents

## Menus and buttons on Liquid Glass (iOS 26+)

Menus inside glass cards used to need several taps (the composer's "+", the new thread's
"Current checkout"). Simulator UI tests open them on the first tap even when they're broken, so these
rules come from testing on a device:

- **No `.interactive()` glass on a card that holds controls.** Interactive glass tracks every touch
  on the card and competes with the `Menu`s inside it. Use `composerGlass()` (`ComposerCard.swift`).
- **A "tap the card to focus" gesture goes behind the content** (`onBackgroundTap`), not as
  `.contentShape(.rect).onTapGesture` on top. On top it races the controls for the same tap.
- **A `Menu` on a screen that redraws often gets its own small view**, `Equatable` on what it shows,
  with `.equatable()` (see `WorkspaceMenu` in `NewThreadView.swift`). Inline, every update from the
  Mac rebuilds the menu under the finger and the tap is lost.
- **A touch area of at least ~44pt**, even when the chip is drawn smaller: `.padding(.vertical, 7)`
  plus `.contentShape(.rect)` on the label and `.padding(.vertical, -7)` on the menu, so the layout
  doesn't move. A near-miss otherwise lands on the card and opens the keyboard.
- To check first-tap opens, `TEST_RUNNER_HELM_MENU_TAPS=1` runs `testComposerMenusFirstTap`. The final
  check is still a finger on a phone.
