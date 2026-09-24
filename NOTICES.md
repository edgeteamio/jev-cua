# Third-party notices

Code in this repository ports ideas and small functions from the MIT-licensed projects below.
Each port carries a comment naming the source file. No source is vendored verbatim.

- **Apple WWDC25 SpeechAnalyzer sample** — `BufferConverter` in `Sources/JevMac/AudioInput.swift`
  follows the sample's AVAudioConverter usage.
- **moritzkremb/jev-voice-browser** (MIT) — question criteria shape, policy gate order, utterance
  continuation, span extraction. Ported in Phases 1 to 3.
- **awlevin/typesafe-computer-use** (MIT) — accessibility walk pruning and AX helpers. Ported in
  Phase 4.
- **trycua/cua** (MIT) — role tables and adopted labels from PR #3914; factorized gates from PR
  #3961. Ported in Phases 4 and 6.
- **awlevin/typesafe-computer-use**, branch `claude/iterative-architecture-testing` (MIT) — row
  mates for duplicated labels; the screen-signature stall rules and the writer hand-off are
  planned from it (issues #1 and #3). 2026-09-22.
- **savka777/jev-use** (MIT) — the menu bar as an action surface, spoken repetition counts,
  `AXSelectedText` insertion before keystrokes, and the AXPress-then-shortcut fallback for menu
  items. Ported 2026-09-20 to 2026-09-22 into `Menus.swift`, `Spans.swift`, `Executor.swift`.

Reviewed and not ported (no code taken): mizorewww/laya-mlx and laya-coreml (Apache-2.0),
trycua/cua's Cua-S1 models (Apache-2.0 adapters). TypeSafe's public documentation informed the
question design throughout.

