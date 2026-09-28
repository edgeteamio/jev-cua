# jev-cua

Voice-driven Mac computer use on TypeSafe's Jev. Speak a command; the app fires the action while
you are still talking. Plan: [NEW_COMBINED_PLAN.md](NEW_COMBINED_PLAN.md).

## Setup

Requirements: macOS 26, Xcode 27 installed (its license does not need to be accepted, see
Toolchain below), a `TYPESAFE_API_KEY` in a `.env` file in this directory.

```bash
scripts/build.sh                 # debug build
scripts/test.sh                  # unit tests (no mic, no network)
scripts/jev-cua doctor           # permissions, speech model, key presence (never prints the key)
scripts/jev-cua doctor --live    # one Noul request to the pinned model, with latency and cost
scripts/jev-cua models           # models the account can use
scripts/bundle.sh                # dist/JevCUA.app, ad-hoc signed as io.edgeteam.jev-cua
```

**The live commands and suites act on this Mac for real:** `say`, `run`, `goal`, and the `sessions`
and `goals` suites open apps, create notes in your Notes, open tabs, and type into the front
window. Run them on a machine and account you are happy to have driven, with nothing sensitive in
front. Answers they get from Jev are cached under the ignored `runs/`, never in the committed cache.

`open dist/JevCUA.app` on first launch runs the doctor with permission prompts and shows the
report. Permissions attach to the bundle id and survive rebuilds.

**Signing.** `scripts/bundle.sh` signs with the Developer ID Application certificate when it
is in the keychain (the maintainers' certificate here), else the self-signed identity from
`scripts/signing-identity.sh`, else ad-hoc. A stable identity matters: TCC keys grants to the
signature, and an ad-hoc signature changes with every build, which reset all three grants twice
during Phase 2. With the Developer ID signature the grants survived every rebuild since.

**Anything that needs a grant runs through `scripts/app-run.sh`.** macOS attributes Microphone,
Speech, and Accessibility to the *parent app* of a binary started from a shell, so
`.build/debug/jev-cua say ...` from a terminal is judged as the terminal, and requesting Speech
that way aborts the process (tccd reads the parent's Info.plist). `app-run.sh` launches the
bundle through LaunchServices (`open -n -W --args ... --cwd $PWD`) and relays its output:

```bash
scripts/app-run.sh doctor --prompt          # request Microphone, Speech, Accessibility for JevCUA.app
scripts/app-run.sh say "open chrome"        # one typed command, executed and verified
scripts/app-run.sh run                      # live voice control (Phase 3)
scripts/app-run.sh ax --walk                # the perception walk of the front window (Phase 4)
```

Accessibility is a toggle in System Settings → Privacy & Security → Accessibility; the prompt
adds JevCUA to the list but the switch is yours to flip (path: `dist/JevCUA.app`). If the
signing identity ever changes, toggle it off and on once.

`open dist/JevCUA.app` (or a double-click) starts the voice app: menu-bar icon, notch overlay,
listening. A missing Accessibility grant shows a dialog with the path and the app keeps running.

### Permissions

| grant | why | prompted by |
|---|---|---|
| Microphone | audio in | first `speech-probe` or `run` |
| Speech Recognition | on-device recognizer | first `speech-probe` or `run` |
| Accessibility | reading the front window's controls and synthetic input (Phase 2+) | `doctor --prompt` or first action |

Screen Recording is not requested; v1 takes no screenshots.

**LuLu:** this Mac runs the LuLu outbound firewall. The first time a new `jev-cua` binary
(debug, release, or the bundle) reaches `api.typesafe.ai`, LuLu shows an alert and blocks until
it is answered. Choose Allow for the process; until then every Jev request times out after 5 s.

### Toolchain

Two things are wrong with the shims on this machine, so the scripts bypass them:

- `/usr/bin/swift` and `xcrun` go through Xcode and refuse to run until the Xcode license is
  accepted (`sudo xcodebuild -license`).
- The Command Line Tools' SwiftPM manifest library is internally inconsistent (module
  interfaces dated after the dylib), so no `Package.swift` links under it.

`scripts/env.sh` therefore invokes Xcode's toolchain binaries directly with `DEVELOPER_DIR`,
`SDKROOT`, and the platform framework paths set. Accepting the license would let plain
`swift build` work too; the scripts keep working either way.

The package has no third-party dependencies. Argument parsing is 40 lines in `CLI.swift`
because SwiftPM's plugin builds for dependencies fail under the direct-toolchain path.

## Phase 0 status (2026-09-19): complete

| acceptance item | result |
|---|---|
| `swift build` and `swift test` pass through the direct toolchain | yes, 19 tests in 5 suites |
| bundle launches and shows the three permission prompts | launched 2026-09-19; Accessibility granted, Speech Recognition prompted by the sfspeech probe |
| `jev-cua models` lists `jev-latest` | yes (2026-09-19, after the LuLu allow) |
| one Noul request to `jev-1.13.0` returns | yes: `is_command` 0.930 on the demo sentence, three identical runs, 317 to 373 ms cold (fresh TLS per CLI run), 306 input tokens, $0.000013 |
| speech cadence table for both providers, primary chosen | complete: dictation primary, SFSpeechRecognizer fallback |

### Speech provider measurement

Run each provider for 45 s and speak about ten short commands with pauses ("open the notes
app", "take a picture of me", "google search norbert wiener"). Then paste the printed table
rows here.

```bash
scripts/jev-cua speech-probe --provider transcriber
scripts/jev-cua speech-probe --provider transcriber-fast
scripts/jev-cua speech-probe --provider dictation
scripts/jev-cua speech-probe --provider sfspeech
```

Each run also writes `runs/speech-probe-<provider>-<timestamp>.md` with every event.

| provider | events | finals | revisions | gap p50 ms | gap p90 ms | onset→text p50 ms | end→final p50 ms | end→final p90 ms |
|---|---|---|---|---|---|---|---|---|
| SpeechTranscriber, default analyzer priority (run 1, 2026-09-19 19:00) | 75 | 12 | 0 | 0 | 3799 | 2523 | 1830 | 2737 |
| SpeechTranscriber, userInitiated (run 3, 19:08) | 118 | 14 | 0 | 0 | 1454 | 3015 | 773 | 1884 |
| SpeechTranscriber(fast), userInitiated (run 4, 19:09) | 126 | 16 | 0 | 0 | 1005 | 904 | 1135 | 1825 |
| **DictationTranscriber(shortForm), userInitiated (run 5, 19:10)** | 106 | 8 | 10 | **208** | 1499 | 603 | 23 | 2111 |
| SFSpeechRecognizer (run 6, 19:14) | 87 | 9 | 2 | 296 | 1787 | 606 | 1325 | 1531 |

Runs 3 and 4 still burst: raising the analyzer priority only moved the burst earlier, and
`fastResults` streams at roughly one update per second. Both also showed punctuation-only
finals after a forced `finalize(through:)` past the decoded audio; the provider now finalizes
only through the last result range and the probe no longer forces commits on analyzer
providers.

Run 5 is the one that matters. `DictationTranscriber` with the `shortForm` content hint and
`frequentFinalization` delivers a new partial every 200 to 300 ms while speaking, each word
visible a few hundred milliseconds after it is said, and finalizes on its own about 1.5 s
after a pause. Ten revisions over 45 s (for example "wiki" → "Wicopee" → "Wikipedia", and
"all right right click on" → "right click on that"), which the Phase 3 controller must
tolerate. Segments span several commands when the pauses between them are shorter than the
finalization gap; the consumed-prefix rule handles that.

Run 1 finding: at the default analyzer priority, every partial for a phrase arrived in the same
millisecond about 2.5 s after speech onset, followed by the final 70 ms later. The transcriber
was not streaming during speech; it emitted the whole hypothesis chain after the phrase ended
(`gap p50` 0, `onset→text` 2523 ms). Accuracy was excellent (11 of 11 commands, "Benioff"
corrected on the final). The provider now sets `SpeechAnalyzer.Options(priority:
.userInitiated)`, and the `dictation` module (`DictationTranscriber`, `shortForm`,
`frequentFinalization`) is offered as a fourth candidate.

Columns: `gap` is the interval between consecutive partial results; `onset→text` is speech
onset (audio above the RMS threshold) to the first text of that segment; `end→final` is the last
loud audio before a commit to the final result. Lower is better everywhere; `revisions` counts
rewrites of already-shown text, which the controller must tolerate.

**Primary provider: `DictationTranscriber(shortForm)`** (`SpeechTranscriberProvider(module: .dictation)`): fastest cadence and self-finalizing. **Fallback: `SFSpeechRecognizer`**: streams at ~300 ms with fewer revisions, but needs 3 s to start and a task restart per segment, and finals only arrive through a forced end-of-audio commit. `SpeechTranscriber` with or without `fastResults` is not usable for mid-sentence action.

## Phase 1 status (2026-09-19): complete

The decision lab (`jev-cua lab`) feeds every word-by-word prefix of every fixture command
through the real question catalog and policy, simulating the session's consumed-prefix rule
after each act, with Jev answers cached in `fixtures/jev_cache.json` (keyed by the request hash,
so any change to a question or the model reruns live).

```bash
scripts/jev-cua lab --heldout fixtures/utterances.heldout.json     # ~1 min live, free from cache
```

| metric | calibration (52 cmds, 15 non) | held-out (21 cmds, 7 non) | required |
|---|---|---|---|
| final intent accuracy | 100% | 100% | ≥ 90% held-out |
| fired sequence correct (compound utterances included) | 52/52 | 21/21 | |
| app / site / span selection | 100% / 100% / 100% | 100% / 100% / 100% | |
| premature acts (before verb + object) | 0 | 0 | 0 |
| false fires on non-commands (negations, dictation with command words, narration) | 0 | 0 | 0 |
| allowlisted commands fired at the first fireable prefix | 23/23 | 9/9 | |
| Jev latency, warm, p50 / p95 | 178 / 250 ms | 179 / 238 ms | |
| input tokens per decision, cost | ~2.9k, $0.00012 | | |

Thresholds tuned on calibration and reported on held-out (all in `Config.swift` with comments):

| threshold | plan | tuned | why |
|---|---|---|---|
| `T.complete` | 0.60 | 0.67 | "launch photo" (before "booth") scored 0.65 and fired wrongly; "scroll down" (before "a bit") scored 0.69 and should fire. Thin 0.04 margin; recheck on real speech in Phase 3. |
| `T.isCommand` | 0.50 | 0.35 | non-commands scored ≤ 0.23 (calibration) and ≤ 0.09 (held-out); "dismiss that" scored 0.42. |
| early-execution stability | two revisions | two revisions **or** intent confidence ≥ 0.85 | the stability rule blocked every early fire on short commands (the confident revision is the second-to-last one) and never prevented a wrong fire; the confidence gate caught each transient. |

Question wording change (q2): `is_command` true-examples widened with short casual commands
("scroll down a bit", "dismiss that", "go ahead") after Jev scored "scroll down a bit" at 0.03
at its final word. Other findings: with no elements on screen "press take photo" is judged
`take_photo`, which does what the user asked; the fixture accepts either. "yes" and "dismiss"
alone are complete commands.

## Phase 2 status (2026-09-19): complete

`jev-cua say "<command>"` runs one typed command through perception, Jev, policy, executor,
verification, and the run log (`runs/<ts>/events.jsonl`, `summary.json`). `--dry-run` stops
before execution, `--step` pauses before each action. `scripts/demo.sh` runs the six demo
commands through the bundle.

Acceptance run (hands off, Developer ID signed bundle, all grants on):

| command | decision | executor | verification | evidence |
|---|---|---|---|---|
| open the notes app and create a new note | `open_app Notes` then `new_note` (two decisions, span split) | 2 ms + 1.3 s | verified, verified | frontmost app; empty note focused (Notes reuses an empty note) |
| make the title say hello | `type_text 'hello'` | 41 ms | verified | focused field value |
| open chrome | `open_app Google Chrome` | 157 ms | verified | frontmost app |
| google search norbert wiener | `web_search google` | 315 ms | verified | address bar URL |
| open x dot com | `open_site x dot com` | 107 ms | verified | address bar URL |
| take a picture of me | `take_photo` | 1.1 s | verified | File > Take Photo disabled for the countdown |

Jev decisions 370–520 ms live at 3.5–6.8k tokens (elements included), 0 ms from cache.

What the live runs changed:

- **First-command scoping (q4) and the span head (q7).** With the whole compound sentence
  judged at once, Jev's intent went to the second clause; the intent, app, site, and span
  questions now say "answer for the first command", the `command_span` head carries examples, and
  when it wavers between two prefixes a joiner ("and", "then") right after the shorter one marks
  the boundary in code. After a consumed command the session drops continuation fillers ("app",
  "and", "then", "please") before deciding on the rest.
- **Frontmost app read live.** `NSWorkspace.frontmostApplication` only updates when the main run
  loop pumps, so a `say` process reported the app that was in front when it started and every
  verification failed against it. The system-wide Accessibility focused application is live.
- **No AppleScript.** The Notes count raised an Automation prompt; verification is AX-only now:
  note-list row count (the biggest list that is not the Folders sidebar), focused empty text
  area, address bar or `AXURL`, Photo Booth's File > Take Photo menu item going disabled for the
  countdown (the library folder is unreadable without a Files grant; the shutter button ignores
  AXPress, the menu item does not).
- **Early app-name gate.** "launch photo" scored complete 0.68 and would have fired before
  "booth"; code now waits while the last spoken word is a prefix of another app's name
  ("photo" → "Photos"). Lab: 100% intent on calibration and held-out, 0 premature, 0 false fires.
- **Installed apps prefiltered** to those sharing a word with the transcript (212 apps cost 6.5k
  tokens per decision); **elements compacted** to one string each, 60 per decision.
- **Cold launches** get 12 s to come to the front, running apps 3 s.

## Phase 3 status (2026-09-19): built; live 50-trial run pending

`jev-cua run` is the live app: `DictationTranscriber` → `VoiceLoop` → `CommandSession` →
executor, with the notch overlay (consumed words dimmed), a status-bar item (listening,
spoken feedback, overlay, runs folder, quit), spoken feedback through `AVSpeechSynthesizer` with the
microphone muted while speaking plus a 300 ms tail, and three stop paths: the kill phrase
("stop", also after a consumed command), ⌃⌥Space (Carbon hot key, no Input Monitoring needed),
and the pointer parked in the top-left corner for 300 ms. The hot key defaults to ⌃⌥J
(`--hotkey ctrl+alt+j` style overrides; ⌃⌥Space was swallowed by another app's event tap on this
Mac) and is registered both as a Carbon hot key and a global key monitor, with each hit logged.
Speech happens only at decision points
that need the user (confirmation, badges, a failure, no field focused, denied, stopped), never on
a routine dispatch: the mic is muted while speaking and an early fire lands mid-sentence.

**Entry point.** `main()` is synchronous: an `async main` runs as one job on the main actor, and
calling `NSApplication.run()` inside it kept that job alive forever, so nothing else queued on the
main actor (overlay updates, the menu's Listening toggle) ever ran while the Carbon hot key,
which fires outside the actor, still worked. UI commands start their setup as a task and enter
the AppKit run loop from `main`; CLI commands run detached with the main thread parked in
`dispatchMain()`.

**Notch overlay.** The default overlay continues the MacBook notch: a black shape at a window
level above the menu bar, sized from the display's safe-area inset and the auxiliary areas beside
the cutout (a simulated notch on displays without one). Idle, it is the notch plus a listening
dot beside the cutout. When you speak it widens to 620 pt and drops out of the notch: a
four-bar mic meter, the transcript with consumed words dimmed, then a row of action chips
(▶ running, ✓ verified, ? unknown, ✗ failed) followed by the verification detail, or an orange
prompt when a confirmation or a numbered choice is waiting. It folds back 1.8 s after the last
chip settles. `--ui pill` restores the bottom-center pill; `--no-overlay` hides both.
`jev-cua ui-preview` renders every state to `runs/ui-preview/*.png` without a microphone.

**Menu-bar icon.** An SF Symbol template image, so it follows the menu bar's appearance: a
microphone while listening, a waveform while you speak, a crossed microphone when paused, a
network warning while Jev is unreachable. The tooltip names the state and flags dry runs. Its
menu: Listening (⌃⌥J), Hold ⌃⌥J to talk, What can I say?, Recent actions, Undo last action,
Spoken feedback, Sounds, Show overlay, Show all speech, Open runs folder, Quit (see the voice-loop
UX pass below).

Utterance boundaries live in `UtteranceAssembler` (pure, tested): the recognizer's chunked finals
plus the volatile tail form one utterance until everything is finalized and the mic has been quiet
for 1.5 s, or until the session consumed all of it. A finalized chunk is reported to the session
as final only after 400 ms of quiet, because with frequent finalization a chunk can end
mid-command ("google search norbert" | "wiener") and a final mid-command would commit a truncated
query; the session's final flag is no longer sticky for the same reason. An utterance never closes
around a volatile tail, or its finalized copy would arrive as a new utterance and fire again; a
quiet tail that the recognizer has not finalized gets a bounded `commitSegment`.

Spoken feedback is `spokenFeedback` in user defaults (default on), the status menu, or
`--speak` / `--no-speak`. The 50-trial acceptance run is pending the grants.

**Follow-ups (2026-09-20, a user request).** A bare phrase right after an action supplies what
that action needs: "open wikipedia" then "mark zuckerberg" searches Wikipedia; "open the notes
app" then "Mark Zuckerberg" types into the note; "google search cats" then "persian cats" searches
again. The state carries `last_action` with its age (15 s window), and a `followup` head (q10)
judges the phrase as `supplies_text`, `new_command`, or `unrelated`; code maps `supplies_text` onto
the site's search template or the focused field, only on a committed phrase, at confidence ≥ 0.60,
and never over a confident command of its own. Verified live: both examples, a search refinement,
chatter after an action ignored, and a new command after an action treated as a command. In the
same breath, "open wikipedia mark zuckerberg" is judged `web_search` on Wikipedia outright (q9),
and a searchable site's home page waits 300 ms for a possible query before opening. A remainder
left after a consumed command needs is-command ≥ 0.55 to stand on its own.

**Realistic phrasing (2026-09-20).** A third lab set, `fixtures/utterances.realistic.json`
(30 commands, 8 non-commands), covers natural requests: "pull up the latest Alex Hormozi YouTube
videos", "when do the vikings play next", "find me a good pasta recipe", "jot down call mom
tomorrow", "can you open chrome for me", "get rid of this dialog", and musings that must not fire
("I wonder when the vikings play next"). Changes: a direct question counts as addressed to the
computer and as a web search (q11); triggers gained natural verbs (pull up, jot down, find me,
show me, check, play, youtube, wikipedia); code cleans the query it selects (drops the site's own
words and leading articles, turns "latest" into YouTube's newest-first sort); a whole question is
its own query when the span head answers none; a trigger's remainder beats Jev's tail pick at
modest confidence ("call mom tomorrow", not "mom tomorrow"). Result: 100% intent, site, and span
on all three sets, zero premature acts, zero false fires. Both headline commands verified live.

Jev handles this phrasing without an LLM. Escalation (Phase 6) is reserved for generation:
composing or rewriting text, splitting multi-step goals, and vision when Accessibility is blind;
Jev keeps the decision to act.

**Noisy rooms (2026-09-20).** With a conversation nearby the mic never went quiet, so commits that
needed silence waited 13 and 53 s. Once the recognizer has produced no new words for 1.2 s the
transcript counts as silent regardless of the mic; the loudness threshold follows the room's noise
floor; scroll's 300 ms settle is transcript-only. Scroll wheel events go through the HID tap at the
window's location (posting to a pid reached no window); verified in Chrome by the page's scroll
offset: a page is 720 px, "a bit" 240 px.

**Editing text, not just adding it (2026-09-20).** "Change the title to groceries" on a note
already titled appended the words and counted as verified, because `type_text` only ever inserted
at the caret and its check was "the value now contains the text". A `type_placement` head (q22)
now says whether the words replace the field's first line (a note's title: change, rename, set,
make the title say), replace everything (replace the text with, clear it and type), or insert;
below 0.60 confidence it inserts, which the user can undo without losing anything. Replacements
select the old text with `AXSelectedTextRange` and wait for the selection to read back before
typing (Notes accepts the set a beat before applying it; the first attempt landed at the old
caret), falling back to Cmd+A or Cmd+Up, Shift+Cmd+Right; their postcondition is the old text
gone, so `Shoppinggroceries` reports unknown, never verified. Verified live in Notes with a
title-and-body note (`groceries⏎Milk and eggs`) and in Chrome's search box; the lab and the goals
suite hold (notes 6/6, form 2/2, switch-apps 4/4). An insert whose caret sits right after a word
now gets a leading space, which removes the suite's one false completion (an "eggshello" that
Notes autocorrected away before the evidence check). `jev-cua ax --focused [--select N]
[--caret N] [--select-keys title|all]` probes what a field lets a client select.

**Menu commands, counts, and AX insertion (2026-09-20, from savka777/jev-use).** Three things
that repo does that we now do too, kept inside our privacy and verification rules.

- *Menu bar as an action surface.* Perception reads the front app's menu bar (`MenuBar`,
  `Sources/JevMac/Menus.swift`), skipping the Apple, Window, and Help menus and the Open
  Recent, Services, and Share submenus, and any item whose title quotes a name — so no window
  titles or file names reach Jev. A `menu_item` intent (q23) and a `menu_target` head over the
  items whose words the transcript could name (plus a few spoken synonyms: refresh→reload,
  bigger→zoom in) let "save", "close the window", "open a new tab", "undo that", "select all",
  "reload the page", "zoom in" run in any app with no per-app code. The executor finds the item
  again by path at press time, checks it is enabled, and verifies by a change in the window
  count, focused window, focused element, selection range, or focused value, or the item's own
  enabled state flipping (Undo greys out after undoing). A short deny list (trash, erase, reset,
  discard, log out, plus the existing send/delete/quit terms) refuses a destructive command even
  when Jev picks it confidently. Verified live: Notes (Select All → selection 11..<11 → 0..<11,
  Undo, Close → window count 1 → 0) and Chrome (New Tab, Reload, Close Tab).
- *Spoken counts.* "Scroll down three times", "go back twice": `Spans.repetitions` reads the
  number in code (only the explicit "n times" / "twice" forms, so a bare number stays an ordinal
  or dictation), and the executor repeats a repeatable action (scroll, back, Return, Escape) that
  many times, each verified on its own, stopping at the first failure and reporting "performed 2
  of 3". A counted scroll counts screens, not the small nudges a bare "scroll down" gives.
  `Candidate.repeats` is the only new field; its summary shows "scroll_down page ×3".
- *AX insertion before keystrokes.* Typing now sets `AXSelectedText` when the field takes it
  (one call, no keystroke race, and no autocorrect mangling a glued word), reading the value
  back before trusting it, since Notes accepts the set a beat before applying it; a process
  where the set is accepted but never applied (Chrome) is remembered and gets keystrokes
  directly. Insert, replace-title, and replace-all all went through the attribute in Notes at
  7–24 ms.

All three labs stay clean under q23 (100% intent/app/site/span, 0 premature, 0 false fires).
`jev-cua ax --focused [--select N] [--caret N] [--select-keys title|all]` probes text fields.

**Dictation boundary experiment (2026-09-20, item 3).** `jev-cua lab --dictation
fixtures/dictations.json` compares our span head against a `type_from`/`type_to` word-boundary
pair (jev-use's approach) on dictations. Result: a tie at 7/10 on 3-19-word cases, failing on
different ones. The span head offered the exact text in all ten (the trigger-remainder span is
the whole payload, so the 32-span cap does not bite until well past these lengths), and from/to
sometimes drops a leading word, producing a plausible run that is not verbatim. Decision: keep
the span head; from/to is not adopted. The experiment and fixture stay for re-measuring if real
dictations start exceeding ~30 words.

**Note body was landing on the title line (2026-09-20, caught in live use).** In goal mode
"make a new note called groceries with milk and eggs as the body" sometimes produced the
single line "groceries milk and eggs": when Jev named a target field for the body clause, the
"start the body on a new line" rule (which fired only for the focused field, not a named
target) was skipped, so the body was inserted right after the title. Two fixes: the rule now
fires whenever the text goes into a multi-line text area, named target or focused field alike
(single-line fields like a form's first/last name still never get a newline), and `typeInto`
honors a leading newline the way the focused path does. The suite's own check hid this — it
only asked whether both strings appeared anywhere in the note — so it now uses
`value_lines_ordered`, which requires title and body on separate lines in order; a title-append
fails as a false completion. Verified: the note reads `groceries⏎milk and eggs`, note workflow
6/6, and the full suite 12/14 with 0 false completions (the two misses are the browser-search
workflow abstaining, not false-completing).

**Repeat the last action (2026-09-21).** "Again", "do it again", "once more", "one more time"
now re-run the previous action. It rides the existing follow-up head — already asked only while
`last_action` is recent — with a third relation, `repeats_action` (q24), so Jev tells a repeat
request ("do it again") from narration ("let me read that again", which correctly does not
fire). Code re-runs `last_action` on a fresh snapshot: a scroll scrolls again, a menu command
re-finds its item by path ("new tab" → "again" opens another tab), a photo snaps again. A click
on a past element is refused (its id is stale). A spoken count applies to a repeatable action
("again twice" → scroll ×2). Verified live in Chrome and on a Wikipedia page. Three labs stay
clean under q24 (100% intent/app/site/span, 0 premature, 0 false fires); the two "go ahead" /
"never mind" confirm fixtures were set to minWords 1 to match the other pending-confirmation
fixtures — a confirmation is resolved on the first word recognized as confirm/cancel, by design.

**Row mates, a session suite, and AGENTS.md (2026-09-22, items 3 and 4 from the awlevin
branch review).** A duplicated label now carries the labels sharing its row — `button 'Buy'
(center; in the row of 'Coldplay')` — in every target head and in state (q25), complementary
to the named container: three "Buy" buttons in one table say nothing by label, and the row is
a fact the layout holds. Running the targets lab after it exposed something older: since the
`menu_item` intent (q23), "close the window" with a visible close button split Jev between a
click and File › Close and waited; a visible control and a menu command that name the same
thing are now one wish (their mass is the intent's, the confident on-screen control wins, and a
`menu_item` with no menu offered clicks the control). Targets back to 69/69.

`jev-cua sessions fixtures/sessions/session.json` is a live regression suite for session mode,
the counterpart of the goals suite, sharing its evidence checks (`SuiteCheck`): retitle without
appending, title then body on its own line, replace the whole note, a follow-up phrase typed
into the new note, a menu command in Notes, a repeat ("again"), and a menu command in Chrome.
7/7 with the Chrome case a tagged known limit: Chrome's profile picker window ("Who's using
Chrome?") was open on this Mac and is Chrome's key window, so File › New Tab by AXPress, ⌘T
through the HID tap, and the strip's + button all left the tab count unchanged; re-run with it
closed. Finding it added two executor facts that stand regardless: a menu item whose AXPress
changes nothing gets its own shortcut sent (read from the item: `AXMenuItemCmdChar` and
modifiers, through the HID tap since Chrome drops app-level accelerators posted to its pid), and
browser tab counts (the strip's tab buttons, through Chrome's own tab groups; a number, never a
title) are menu evidence, so "new tab" and "close tab" can verify. `jev-cua ax --tabs` and
`--menu-item "File › New Tab"` probe both. `AGENTS.md` now holds the working rules: which suite
to run for which change, and that every ad hoc phrase sequence or goal is proposed as a case.

**Notch polish.** Chips read as a person would say them ("Open Notes", "New note", "Retitle
“groceries”", "Scroll down ×3", "File › Close" as "Close") instead of action kinds; evidence
arrows are "→"; the collapsed indicator is brighter with a soft glow so it reads on the band.

**Voice-loop UX pass (2026-09-28, from a review of the 17 live `run` sessions in `runs/`).**
Over 54 live dispatches, last word → dispatch was 941 ms at p50 against the plan's 600 ms: the
early-fire intents met it (`open_app` 504, `open_site` 519, `scroll_down` 455 ms) and everything
that waits for a committed clause did not (`type_text` 956, `web_search` 1139, `click_element`
1233 ms). The narrated session of 2026-09-24 named the rest: the status line flickered "not a
command" several times a second, "Wikipedia for Sweden" searched `for Sweden`, and "or Sweden" on
a Wikipedia page went to Google. Policy version p2. What changed:

- *One commit window* (`Policy.commitWindowMs`). Gate 4 held free text for `silenceCompleteMs`
  (900), so the 600 ms `payloadSilenceMs` check behind it never bound. The window is now one
  function per intent; it returns 900 for every intent until the owner picks the rule (6 of 118
  in-phrase word gaps in the logs fell between 600 and 900 ms, so shorter is not free).
- *Armed decisions.* A clause waiting only for the words to stop shows its action as a dashed
  ghost chip ("⋯ Search google for “Minnesota Vikings”"); when the window passes with the words
  unchanged, the tick runs the policy again on the answers in hand and acts, with no second Jev
  call (~160 ms whenever the cache missed), logged with trigger `armed`. Once per revision;
  element-targeted actions are shown but decided again, since their element may have moved.
- *Only what needs you reaches the status line* (`Feedback`): no "deciding…", no chatter, no
  timing waits; a finished clause missing something ("search for what?", "no field focused"), a
  refusal, a cancellation. Chatter keeps the notch folded while the dot brightens with your voice;
  "Show all speech" restores the old behavior.
- *The site in front.* Session decisions now send `page_host` (as goal mode does); a search that
  names no site searches the catalog site open in the browser, else Google. `cleanQuery` drops a
  leading "for" or "about" ("Wikipedia for Sweden" → `Sweden`).
- *Confirmations lapse* after `candidateTtlMs` (8 s); the constant was never read, so a "yes"
  minutes later still ran a gated action and the notch stayed open on the prompt.
- *Chimes for state changes.* Pause, resume, a hold, and "stop" play a system sound (the mic is
  muted for the chime's own length, 0.1 to 0.5 s) instead of speaking, which muted it for about a
  second and cost the first words of the next command. "Sounds" toggles them.
- *Outages.* A transport error, timeout, 5xx, overload, or rejected key turns the dot orange, shows
  "can't reach Jev · timed out", and is spoken once; the next answer clears it. The live app's
  client gives up after 2 s (the CLI keeps 5): a decision that old is stale.
- *Hold-to-talk* (`--hold-to-talk`, or the menu; remembered). Nothing is heard or sent to Jev
  until ⌃⌥J is held; on release the recognizer gets 350 ms for its last words, the utterance goes
  to the session as final (release is the end of speech, no silence window), and the gate closes
  without cancelling anything. Words the recognizer repeats across a release are stripped, and a
  key-state poll catches a release both key paths missed.
- *Discoverability and undo.* "What can I say?" (or the menu item, or a click on the notch in
  hold mode) shows examples for the app and page in front, answered in code with no model call;
  hovering the notch suggests one. "Recent actions" lists the last eight with their outcome, and
  "Undo last action" reverses only what has a safe inverse: Back after a navigation in the
  current tab, Edit › Undo after typing or a new note, through the executor with verification.

- *The lock screen.* The first sessions run of this pass (`runs/2026-09-28T12-02-04Z`) went on a
  locked Mac: every case failed with `loginwindow` in front, as `AGENTS.md` warns, and one case's
  Return reached the lock screen. While `com.apple.loginwindow` is in front nothing is decided or
  run and the words are dropped, so nothing said near a locked Mac goes to Jev either; it is also
  on the deny list.

Tests: 104 unit and replay tests (18 new), 112 replay scenarios (3 new: the open-page search, a
search fired from its armed decision, a lapsing confirmation). Labs with `--installed-apps`
unchanged: calibration 52/52, held-out 21/21, realistic 31/31 (the live "let's do let's
Wikipedia for Sweden" added), 100% app/site/span, 0 premature, 0 false fires. `jev-cua
ui-preview` renders the new states (armed, chatter, examples, offline, hold idle). Sessions suite
on an unlocked screen (`runs/2026-09-28T12-10-14Z`): 6/7. The Chrome menu command case passes
with the profile picker closed and is untagged. "Title then body on its own line" missed: the
bare phrase "milk and eggs" after Return scored follow-up 0.54 against the 0.60 bar, so it was
taken for chatter. Jev scored the same state 0.63 to 0.77 on 2026-09-22; the state differs only
in the note list on screen (32 elements, not 34), so this is a margin that was always thin, not
a change in what Jev sees.

## Phase 4 status (2026-09-20): complete

`AXWalker` walks the focused window with one `AXUIElementCopyMultipleAttributeValues` per node,
prunes off-display, tiny, menu, and container nodes, keeps enabled pressables and text roles,
adopts labels from shallow static text, dedupes by role/text/frame, collapses identical
descriptions (counted in the log), lists labelled off-screen pressables separately, drops
deny-listed labels, and stops at 4000 nodes or 0.6 s. Perception refreshes in the background on
app activation and AX focus-window / focused-element / window-created notifications.

Target heads `click_target`, `type_target`, and `offscreen_target` (q5) are asked only when their
element subset is non-empty. The policy acts at target confidence ≥ 0.45 with top probability
≥ 0.35, otherwise shows numbered badges for the contenders (probability ≥ 0.08, up to four) and
a spoken number ("two", "the second one") resolves in code with no model call. A named field
beats the focused one for `type_text`. The executor re-checks role, label or frame, and a
hit-test at the element's centre before pressing (`AXPress`, then `AXConfirm`/`AXShowMenu`,
then a synthetic click only after a verified AX refusal).

Walk cost on this Mac (focused window, all candidates): Chrome 58 elements in 53 ms, Photo Booth
6 in 72 ms (shutter button found by label), Notes 34 elements in the 0.6 s cap (Notes answers
Accessibility at ~2.4 ms per node, so its deep note list is cut; toolbar and folders come first
because the walk is breadth first). In the live app the walk runs in the background on app
activation and focus changes, so decisions read a warm snapshot.

Fixture capture and scoring: `scripts/app-run.sh ax --walk --json > fixtures/targets/notes.json`,
add `commands` with the expected element id (`none` or `ambiguous` allowed), then
`scripts/jev-cua lab --targets fixtures/targets`, which reports selection accuracy and candidate
coverage separately. A command may also name `altIntents` that do the same thing without a
target ("click new note" as `new_note`).

Acceptance (2026-09-20), 20+ commands per app against captured element lists:

| app | elements | correct | coverage | note |
|---|---|---|---|---|
| Notes | 38 | 24/24 | 24/24 | rows carry their list's name ("Folders", "My Notes as List") so "the first note" is not the first folder (q12) |
| Photo Booth | 9 | 22/22 | 22/22 | window controls labelled from their subrole; shutter by menu item |
| System Settings | 31 | 23/23 | 23/23 | every selection right, every click then refused by the deny list, as the plan requires |

Personal labels in the captures (account name, folder and note titles) were replaced with generic
ones before commit. Walk time is under 100 ms for Chrome and Photo Booth; Notes is capped at
0.6 s (see above).

## Phase 5 status (2026-09-19): replay done; recording and numbers pending grants

`jev-cua replay runs/<ts>` re-runs the policy over the answers a run logged (unredacted runs carry
answers, spans, and context per decision) with the current thresholds and candidate builder, and
diffs outcomes and candidates; exit code 2 on any change, `--json` for tooling. The replay suite
is 102 scenarios (`fixtures/transcripts/scenarios.json`): the original 33, cadence variants
(final only, word by word, chunked with pauses, silence without a final), the chunked-final
hazard, non-sticky finals, kill phrases after consumed commands, back-to-back utterances, and
element scenarios (confident click, ambiguous → number / cancel / out of range / new command,
deny-listed label, typed text to the focused field). The uncut demo recording and the phase
numbers wait on the grants.

## Phase 6 status (2026-09-20): goal mode built and measured on seven workflows

`jev-cua goal "<goal>"` runs the `TaskRunner` loop: observe → Jev's gates (`goal_achieved`,
`blocked`, `needs_reobserve`) and `next_action` → candidate built in code → execute → verify,
with stop rules (confidence floor, two consecutive no-ops, step and time budgets), a `clause` head
that names which part of the goal the next action serves (its arguments are then re-asked over
that clause, one extra request for multi-clause goals), history entries tagged with their clause,
never repeating a verified or unverified action, and a browser page host (never the URL or title)
in the state. Intake asks `goal_missing` and `goal_compound` once. Escalation (`Escalating`:
planner, writer, composer) runs behind a budget and appears in the trace; `AnthropicEscalation`
(Haiku 4.5, JSON-only replies) activates when `ANTHROPIC_API_KEY` is present. It was not set on
this Mac, so every number below is Jev only; the escalation wiring is covered by fake-backed tests.

`jev-cua goals fixtures/goals/phase6.json --runs 5` runs the suite, two phrasings per workflow,
and checks completion evidence from a fresh observation after each run (page host, page text,
form field values by label, focused value, forbidden actions), independently of the loop's verdict:

| workflow | verified | notes |
|---|---|---|
| browser search and open a specified result | 8/10 | two abstains when Chrome already showed the results page |
| navigate back across known pages | 10/10 | in-tab navigation; Back via the toolbar button, verified by the committed URL |
| fill a local fixture form with supplied literals | 10/10 | fields by label; values only; no submit |
| cart task on a demo shop, stop before checkout | 10/10 | page-button clicks verified by page text; checkout deny-listed |
| create a note with title and body | 10/10 | title and body clauses; body on a new line |
| take a photo | 10/10 | |
| switch apps and continue a pending task | 9/10 | one false completion: typed text verified but not in the note's value |

Total 67/70 (96%), 0 failed, 1 false completion, $0.085 for 70 runs, 2 to 5 s per goal. Not yet
hosted: find a fixture file in Finder, move a disposable file (Finder perception untested),
research a page and create a note (needs the writer). The plan's Jev-only versus escalation
comparison waits on a key.

Findings that shaped the loop: Jev judged "create a new note" achieved once Notes was in front
(fixed by demanding history evidence per named action); it leaned toward "look again" on a fresh
screen (looks now need something to have happened); argument heads read `transcript`, which goal
state lacked, so "switch back to notes" resolved to Chrome twelve times (the two-phase clause
step); AXPress on web buttons is sometimes ignored and a synthetic click needs a click count of 1;
the address bar echoes typed text before a navigation commits (verify by the web area's URL);
Chrome reuses a tab for a re-opened file URL (the suite reloads); the web-area search needs a
wide node budget or the page reads as empty.

## Layout

```
Sources/JevCore/     contracts, config, Jev client and cache, transcript, spans, questions, state, policy,
                     session (utterances, ledger, dispatch), utterance assembler, run log, lab
Sources/JevMac/      audio input, speech providers, permissions, AX helpers and walker, perception,
                     executor, voice loop, speaker, cadence stats
Sources/jev-cua/     CLI entry, doctor, models, speech-probe, lab, say, run, goal, goals, trials, replay, ax, ui-preview
Tests/               JevCoreTests (wire types, env, transcript, spans, policy, session replay, assembler), JevMacTests
Resources/           Info.plist for the bundle
scripts/             env.sh, build.sh, test.sh, jev-cua, bundle.sh, app-run.sh, demo.sh
fixtures/            calibration and held-out utterances, replay scenarios, target captures, Jev answer cache
runs/                probe and lab reports, say/run logs (gitignored)
```

## License

MIT, copyright 2026 EdgeTeam LLC. Third-party notices are in `NOTICES.md`.
