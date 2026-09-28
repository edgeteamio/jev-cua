# jev-cua: combined implementation plan

Written by Fable 5.1 on 2026-09-18, merging `FABLE_PLAN.md` (concrete voice decision layer) with
`CODEX_PLAN.md` (reusable engine contracts and verification discipline) under the decisions the project owner
confirmed. This is the canonical plan for Opus.

**Status 2026-09-19:** approved by the project owner. Implementer: Claude. Phases 0 and 1 complete; Phases 2 and 4 complete; Phase 3 built, 50-trial acceptance in progress; Phase 5 replay and suite
done, recording pending; Phase 6 goal mode built and measured on seven of the ten workflows
(67/70 verified, Jev only), escalation providers wired but unmeasured (no key). README has the numbers. `.env` with `TYPESAFE_API_KEY` is present; `jev-cua doctor` reports it
present before the Phase 0 smoke request. Do not implement past a red phase. Supersedes
`FABLE_PLAN.md`, `CODEX_PLAN.md`, and `COMBINED_PLAN.md`, which remain as history.

Read order: sections 2 to 4 say what and why; 5 to 11 are the spec; 12 is the build order with
acceptance criteria; 13 to 15 are testing, references, and environment.

---

## 1. Outcome

A native Mac app that turns speech into computer actions through Jev, built as a vertical slice
of a reusable engine. The first deliverable is Andy Gao's demo, done better: a non-activating
transcript pill, actions that fire while the sentence is still being spoken, every decision
replayable offline, and no false fires during unrelated speech. The same engine then takes typed
goals, runs a bounded observe-decide-act-verify loop, and escalates to a stronger model only for
planning, writing, or visual gaps, behind a budget.

The v1 demo script, spoken continuously:

1. "open the notes app and create a new note" → Notes activates on "open the notes", a note is
   created on "create a new note"
2. "make the title say hello" → "hello" typed as the first line
3. "open chrome" → Chrome activates
4. "google search norbert wiener" → Google results for the query
5. "open x dot com" → https://x.com
6. "take a picture of me" → Photo Booth opens and takes a photo
7. "click the first result" (phase 4) → Jev picks an element from the accessibility tree

## 2. Decisions (confirmed by the project owner on 2026-09-18, do not reopen)

| Decision | Choice | Why |
|---|---|---|
| Scope order | Voice demo first, built on the engine contracts; goal mode after | The demo is the target; the streaming gates are the hard part; the contracts make it a slice, not a throwaway |
| Language and process | One Swift package, one process. No TypeScript core, no Python, no daemon | `SpeechTranscriber` is Swift-only and verified working; the latency path stays in-process; permission prompts attach to a real bundle |
| Speech | macOS 26 `DictationTranscriber` (`shortForm`, `frequentFinalization`, volatile results) on a user-initiated `SpeechAnalyzer`; `SFSpeechRecognizer` on-device behind the same protocol as fallback | Measured 2026-09-19 (README): dictation streams a partial every 200 to 300 ms; `SpeechTranscriber` bursts after the phrase or updates once a second |
| Executor | Own executor (NSWorkspace, AX, CGEvent, NSAppleScript) behind a `ComputerAdapter` protocol | Cua Driver 0.28.2 is pre-release. Its SDK can load the runtime in-process without the app, but that still brings a Rust native library, telemetry on by default, and unsettled permission attribution, for a demo that needs six actions. It stays an optional later spike behind the same protocol |
| Perception v1 | Accessibility tree only, hard-pruned, capped at 100 | Fast, no Screen Recording permission. Chrome DevTools Protocol and OCR deferred |
| Model | `jev-1.13.0`, pinned | Thresholds are tuned per version |
| Free text | Candidate spans only through phase 5; a writer model in phase 6 behind a budget | Jev cannot generate text; spans cover the demo |
| Stronger models | None until phase 6, then planner, writer, and vision escalation with call and cost budgets, visible in the trace | owner's call: allowed but late |
| Safety | Deny list enforced twice, operation allowlist by construction, execution ledger, unknown-outcome state; a model probability can add a confirmation but never remove one | Codex's rule; Fable's mechanics |
| Deny apps | No click or type inside Messages, Mail, Terminal and other terminal emulators, System Settings, Keychain Access, password managers (1Password, Bitwarden), Script Editor, Automator, Disk Utility, Activity Monitor, and LuLu; `open_app` may still bring them forward except System Settings writes | macbrow's blocked-app list; the demo needs none of them |
| Base repo | None; borrow by file (section 14) | macOS-use is a stale LLM loop; Moritz is browser JS; Cua is heavy |

## 3. Architecture

```
 mic ─► SpeechProvider (DictationTranscriber; SFSpeechRecognizer fallback)
            │ TranscriptEvent(utterance, revision, text, isFinal)
            ▼
       CommandSession (actor)      throttle 150 ms · max wait 400 ms · one in-flight + latest pending
            │                      utterance ids · revisions · intent epochs · consumed-prefix ledger
            ├─► Perception         frontmost app, focused field, ≤100 AX elements → Observation(snapshotId)
            ├─► Spans              payload spans, spoken URLs, number words (pure code)
            ├─► Questions + JevClient   ONE request: intent · app · site · target · spans · gates
            │        │
            │        ▼
            │   Policy             act / wait / ignore / confirm / disambiguate, with reasons
            │        │
            ▼        ▼
       Executor (actor)            single serialized queue · precondition recheck · ledger entry
            │
            ▼
       Verify                      cheapest trustworthy postcondition → verified / failed / unknown
            │
            ▼
       Overlay · StatusBar · RunLog (runs/<ts>/events.jsonl)
```

Goal mode (phase 6) reuses everything below `CommandSession`: a `TaskRunner` actor replaces the
utterance state machine with a subgoal loop, and the same `Observation → Candidates → Decision →
Executor → Verify` chain runs each step.

Concurrency: Swift actors. `CommandSession` owns utterance state and the ledger. `Executor` owns
dispatch and never runs two actions at once. AppKit work is `@MainActor`. Speech results are an
`AsyncSequence` consumed by one task. Jev requests are `Task`s cancelled on supersession.

Timing budget from the last spoken word of a closed-set command:

| Phase | Target |
|---|---|
| recognizer volatile result cadence | 200 to 300 ms measured (DictationTranscriber, Phase 0 run 5) |
| throttle | 150 ms, max wait 400 ms during continuous speech |
| perception (cached 1.5 s, invalidated after every action) | ≤ 100 ms, usually 0 |
| Jev request (1 to 4k input tokens) | 100 to 350 ms |
| policy, precondition recheck, dispatch | < 20 ms |
| **last word → dispatch** | **≤ 600 ms median** |
| **stable clause → visible response** (Codex metric) | **p50 ≤ 700 ms, p95 ≤ 1500 ms** |

## 4. Core contracts (`Sources/JevCore/Contracts.swift`)

Codex's contracts, trimmed to what phases 1 to 6 use. All are `Codable` and `Sendable` so they
serialize into the run log and replay fixtures unchanged.

| Type | Fields |
|---|---|
| `Utterance` | id, physicalId, revision, text, isFinal, startedAt, updatedAt, consumedPrefix, intentEpoch |
| `Observation` | snapshotId, takenAt (monotonic), app (name, bundleId, pid), focusedField?, elements (≤100), truncated, tookMs |
| `Element` | id ("e01".."e99"), role, text (≤60), where (3x3 grid word), editable, secure, frame; the AX reference is held outside the contract and never serialized |
| `Candidate` | id, snapshotId, action (typed enum with all arguments), targetElementId?, payload?, tier (low, medium, gated), preconditions, expectedPostcondition |
| `Decision` | snapshotId, candidateSetId, outcome (`act(candidateId)`, `wait(reason)`, `ignore(reason)`, `confirm(candidateId)`, `disambiguate([candidateId])`), answers (raw Jev answers), reasons (gate table), model, latencyMs, usage, requestId |
| `LedgerEntry` | dispatchId, utteranceId, revision, snapshotId, candidateId, dispatchedAt, status (acknowledged, failed, unknown) |
| `ActionResult` | dispatchId, status, detail, tookMs; never declares task completion |
| `Verification` | dispatchId, expected, observed, outcome (verified, failed, unknown), evidence (frontmostApp, fieldValue, url, noteCount, snapshotDiff, none), nextStep |
| `Task` (phase 6) | id, goal, subgoals, constraints, stepBudget, timeBudget, escalationBudget, cancelled |

Rules that live in code, not in the model:

- Jev only ever returns an option id from a set code built. Unknown, stale (different snapshotId),
  denied, or malformed picks are rejected before dispatch.
- Every answer is validated against the question that produced it before anything reads it
  (jev-ultrafast's `validate_choice`): a Choice's probability keys must equal the option set,
  every probability and the confidence must be finite and within 0 to 1, the probabilities must
  sum to 1 within 0.02, and the reported choice must be the argmax; a Noul must be finite in 0
  to 1; a Score's probability keys must be level indices. A failed check makes the whole
  response malformed and the decision `wait("malformed answer")`. Implemented in `JevClient`
  in Phase 0.
- A `Decision` is admitted only if its utterance revision and intent epoch are still current, the
  snapshot is still fresh, and the task is not cancelled.
- Immediately before dispatch the executor re-checks the target: the app is still frontmost, the
  element token still resolves and is enabled, the focused field is still the same. A failed
  recheck produces `wait("stale target")` and a re-observe, never a blind click.
- The recheck is semantic, not just liveness (jev-ultrafast's per-target guard): the token's
  current role, title or description, value, and enabled state must equal what the snapshot
  recorded for that element id. Before any synthetic click at a frame center,
  `AXUIElementCopyElementAtPosition` at that point must return the element or one of its
  descendants; otherwise the control is covered and the click is refused. AX press does not
  need the hit-test, but it still needs the semantic guard.
- Every dispatch writes a `LedgerEntry` first. A lost acknowledgement leaves `unknown`; the next
  step is to observe, not to retry.

## 5. Perception (`Sources/JevMac/Perception.swift`)

Produce an `Observation` in under 100 ms from the frontmost app's focused window.

- Before the first walk of any app, set `AXUIElementSetMessagingTimeout` on its application
  element to 0.3 s so a hung or slow app fails fast instead of stalling the decision, and set
  `AXManualAccessibility` to true on the same element (tiptour): Electron apps such as Slack,
  VS Code, Discord, Notion, and Cursor expose an empty tree until that attribute is set. For
  Chrome and other Chromium browsers set `AXEnhancedUserInterface` instead; without it the
  web content is a single group. Both are no-ops on native apps and are set once per pid.
- Read each node's attributes with one `AXUIElementCopyMultipleAttributeValues` call (role,
  subrole, title, description, value, enabled, position, size, children) instead of one IPC
  per attribute (tiptour). The 100 ms budget depends on this.
- Root: `AXFocusedWindow`, fall back to `AXMainWindow`, then `AXWindows[0]`.
- Skip subtrees whose frame misses the display, nodes under 4 pt in either dimension, and
  `AXMenu` and `AXMenuBar` subtrees. A nameless `AXGroup` is never a candidate itself, but its
  children are still walked; pruning a container must not hide the controls inside it.
- Keep an element if it is enabled and supports `AXPress`, `AXConfirm`, `AXShowMenu`,
  `AXIncrement`, `AXDecrement`, or has a text-entry role (`AXTextField`, `AXTextArea`,
  `AXSearchField`, `AXComboBox`, `AXSecureTextField`). Exclude container and decoration roles.
- Text: `AXTitle`, else `AXDescription`, else adopted from shallow `AXStaticText` children joined
  and capped at 80 chars. Cap the sent text at 60.
- Stop at 4000 nodes or 0.6 s and set `truncated`.
- Cap at 100 elements in reading order, viewport first. Dedupe by (role, text, frame). Then
  collapse candidates whose description as sent to Jev (role, text, `where`) is identical:
  tiptour measured that on an exact tie Jev breaks toward the first option key and still
  reports high confidence, which would read as discrimination it did not do. Identical
  descriptions become one candidate whose frame is the first occurrence, and the run log
  records the collapsed count.
- Keep perception warm (tiptour refreshes detection continuously): subscribe with
  `AXObserver` to `kAXFocusedWindowChangedNotification`, `kAXFocusedUIElementChanged`, and
  `kAXWindowCreated` on the frontmost app, and to `NSWorkspace.didActivateApplication`, and
  refresh the snapshot on those events in the background. A decision then reads a snapshot
  that is already fresh instead of paying for a walk; the TTL remains the ceiling.
- Off-screen pressables (Phase 4 option, from awlevin's `press_offscreen`): labelled controls
  pruned for being off the display but still supporting `AXPress` are kept in a separate list
  capped at 120, deduped by role and label, and minus any label the visible list already has.
  They are offered to Jev as their own `offscreen_target` head only when the list is non-empty.
  A refused press on one is a no-op; there is no pixel to fall back to.
- Deny list applied here: elements whose text contains a denied term are dropped before they can
  become candidates.
- `focusedField` from the app's `AXFocusedUIElement`: role, label, placeholder, value preview
  (≤80 chars), `secure`.
- Never collect window titles, clipboard, or file paths.

Chrome's active tab URL via `NSAppleScript` (`tell application "Google Chrome" to get URL of
active tab of front window`) is read only for verification and the run log, never sent to Jev.

## 6. State sent to Jev (`Sources/JevCore/JevClient.swift`)

```json
{
  "transcript": "open the notes app and cre",
  "transcript_is_final": false,
  "frontmost_app": "Finder",
  "focused_field": null,
  "pending_confirmation": null,
  "recent_actions": ["open_app Chrome", "web_search 'norbert wiener'"],
  "elements": [
    {"id": "e01", "role": "button", "text": "Take Photo", "where": "bottom-center"}
  ]
}
```

- `transcript`: the normalized view (lowercase, punctuation stripped, ≤400 chars, consumed prefix
  removed) used for intent. The raw transcript is kept on the `Utterance` and is never modified;
  every candidate span carries offsets into the raw text, and the payload that gets typed or
  searched is sliced from the raw text, not from the normalized view.
- `recent_actions`: last three, short strings. The only memory in voice mode.
- `elements`: empty through phase 3 (fast path near 1k tokens); populated from phase 4.
- Goal mode adds `goal`, `subgoal`, and `history` (last 8 as `selected_id` + `outcome`).
- Never include the key, window titles, clipboard, element tokens, or screenshots.

Client: `URLSession` POST to `https://api.typesafe.ai/v1/systemone`, bearer key, `model`
pinned, per-attempt timeout 5 s, one retry on 429/529 honouring `Retry-After` only while the
utterance is still current. Behind a `JevDeciding` protocol so tests inject fixture answers.

## 7. Questions (`Sources/JevCore/Questions.swift`)

All in one request. Question ids are not sent to the model, so every `instructions` is a complete
question naming the state field it reads. Criteria use the contrastive `{what, not_for, examples}`
shape because Jev reads literally and overlapping options read as doubt.

**`intent`** (Choice): "Which Mac action does the user ask for in `transcript`? Judge the words
said so far. If the sentence is unfinished, pick the action the words already commit to; if no
action is recognizable yet pick none. `frontmost_app` and `elements` describe what is on screen."

| option | what | not_for | examples |
|---|---|---|---|
| `open_app` | Open, launch, switch to, or go to a named Mac application | Opening a website; creating a note | "open the notes app", "open chrome", "switch to finder", "launch photo booth" |
| `new_note` | Create a new note in Apple Notes | Typing into an existing note; opening Notes alone | "create a new note", "make a new note", "new note" |
| `web_search` | Search the web or a named site for a topic or phrase | Opening a site's homepage; typing into a field that is not a search | "google search norbert wiener", "search for alan turing", "look up typesafe jev", "search youtube for lofi" |
| `open_site` | Open a specific website by name or spoken domain in the browser | Searching; opening a Mac app | "open x dot com", "go to wikipedia", "take me to github" |
| `take_photo` | Take a picture with the camera in Photo Booth | Opening Photo Booth without taking a picture | "take a picture of me", "take a photo", "snap a picture" |
| `type_text` | Type or enter specific text into the focused field, note, or document, including setting a note's title | Running a web search; pressing enter alone | "make the title say hello", "type hello world", "write good morning", "call it groceries" |
| `click_element` | Click, press, open, select, or choose a control that is on screen in `elements` | Opening an app or site by name; typing | "click the first result", "press take photo", "open the second link", "select the dark option" |
| `press_enter` | Press Return to submit or confirm the focused field | Typing text; clicking a named button | "press enter", "hit return", "submit" |
| `press_escape` | Press Escape to dismiss a dialog, popup, or menu | Cancelling a pending confirmation | "press escape", "dismiss that", "close the popup" |
| `scroll_down` | Scroll or move down in the front window | Scrolling up; going back | "scroll down", "scroll down a bit", "go to the bottom", "page down" |
| `scroll_up` | Scroll or move up | Scrolling down | "scroll up", "back to the top" |
| `go_back` | Go back to the previous page in the browser | Scrolling up; closing a window | "go back", "back", "previous page" |
| `confirm` | Approve the action the assistant asked to confirm (`pending_confirmation` is set) | New commands | "confirm", "yes do it", "go ahead" |
| `cancel` | Cancel, never mind, or stop the pending action or the assistant | Going back in the browser | "cancel", "never mind", "stop" |
| `none` | Not a command to the computer, or nothing recognizable yet (fragment, filler, talking to a person, a negated command) | Anything that clearly matches another option | "um", "okay so", "what do you think", "open the", "don't open notes" |

**`app`** (Choice, speculative): "Which Mac application does the user name in `transcript`? Only
what is explicitly said; pick not_stated if no app is named." Options: the catalog entries
`notes`, `chrome` ("google chrome, chrome, the browser"), `safari`, `photo_booth`, `finder`,
`messages`, `mail`, `calendar`, `music`, `terminal`, `system_settings` ("settings, system
settings, preferences"), followed by every other installed application (macbrow's dynamic
`apps` source): names read from `/Applications`, `~/Applications`, and
`/System/Applications` at launch and refreshed every few minutes, deduped against the
catalog, each described by its name with "(running)" appended when it is, capped so the
whole head stays under 200 options with running apps kept first, plus `not_stated`. Code maps
options to bundle identifiers. This replaces `other_named_app` and the deferred fuzzy match.

**`site`** (Choice, speculative): "Which website or search engine does the user name in
`transcript`? Only what is explicitly said." Options: `google`, `x_twitter` ("X, twitter, x dot
com"), `youtube`, `wikipedia`, `github`, `reddit`, `amazon`, `hacker_news`, `the_web` ("a general
search with no site named"), `other_named_site`, `not_stated`. Code owns home URLs and search
templates.

**Target heads, one per operation** (Choice, Phase 4, only when the matching element subset is
non-empty). jev-ultrafast's rule: a head contains only elements compatible with its operation,
and code consumes only the head matching the chosen intent, so a click can never land on a text
field and a type can never target a button.

- **`click_target`**: "If the next action is to click, which element in `elements` is the one
  the user refers to in `transcript`? Each element has an id, a role, visible text, and a coarse
  position; the options are the ids of the clickable elements. Elements are in visual reading
  order, so 'first' means the earliest matching one. Pick none if the command does not refer to
  any clickable element on this screen." Options: ids of pressable, selectable, and link
  elements, described as `"button 'Take Photo' (bottom-center)"`, plus `none`.
- **`type_target`**: "If the next action is to type, which editable field in `elements` does the
  user name in `transcript`? Pick focused if the command names no field and the text should go
  into the currently focused field. Pick none if there is no editable field to type into."
  Options: ids of editable, non-secure elements, plus `focused` and `none`. In Phases 2 and 3
  this head is absent and `type_text` always uses the focused field.
- **`offscreen_target`** (option, see section 5): "If the needed control is not visible but the
  app exposes it, which of these labelled off-screen controls should be pressed?" Options: the
  off-screen list plus `none`.

Every target head repeats the operation it assumes in its own instructions, because questions
cannot see one another's answers.

**`text_span`** (Choice, only when spans exist): "Which option is exactly the text the user wants
typed or searched, as spoken in `transcript`? Options are verbatim candidate spans. Choose the span
that contains only the payload, without command words (type, search for, make the title say). Pick
none if nothing should be typed or searched."

**`url_span`** (Choice, only when a domain-like span exists): "Which option is the web address the
user wants to open, as spoken in `transcript`? Pick none if no address is mentioned."

**`complete`** (Noul): "Has the user finished saying the command in `transcript`, so it can be
executed now without waiting for more words? Speech arrives word by word. A command is complete
when its verb and any required object are present: an app for open, a query for search, an
element for click, text for type." true: "Complete, actionable command", examples ["open the notes
app", "take a picture", "google search norbert wiener", "click the first result"]. false: "Cut off
before the required object; more words are clearly coming", examples ["open the", "search for",
"click the", "make the title say", "google search"].

**`is_command`** (Noul): "Is `transcript` an instruction addressed to this computer (open, search,
click, type, scroll, take a photo, confirm, cancel)? Chit-chat, narration, talking to another
person, reading aloud, a negated instruction, or a stray fragment is not a command." true examples
["open chrome", "take a picture of me", "scroll down"]. false examples ["I think we should get
lunch", "so this is the demo", "what did you say", "don't open notes", "the notes app is nice"].

**`destructive`** (Noul): "Would carrying out the action in `transcript` on the current screen
send a message, send an email, post publicly, pay, buy, delete, sign out, quit an app, or
otherwise do something hard to undo? Opening apps and sites, searching, scrolling, typing into a
note, and taking a photo are not destructive." true examples ["click send", "press delete", "click
buy now", "quit the app"]. false examples ["open notes", "take a picture", "type hello", "scroll
down"].

**`scroll_amount`** (Score, speculative): levels ["A little: a few lines (a bit, slightly)", "One
screen, or no amount specified", "All the way to the end (top or bottom)"].

Phase 6 adds, per Cua's factorized recipe: **`goal_achieved`** (Noul: "Is the goal already
achieved in the observed state, so that no further action is needed?"), **`blocked`** (Noul:
"Progress is blocked by a login wall, permission prompt, error dialog, or information that is not
on this screen"), and **`needs_reobserve`** (Noul: "Has the observed state changed or is the
target ambiguous, so that a fresh observation is required before acting?"), plus the reserved
candidates `reobserve` and `abstain` in the selection choice.

## 8. Spans (`Sources/JevCore/Spans.swift`, pure code)

- **Payload spans.** For each trigger phrase found, the remainder after it is a candidate:
  `search for`, `search`, `google search`, `google`, `look up`, `type`, `write`, `enter`, `say`,
  `make the title say`, `title it`, `call it`, `name it`, `titled`. Then every word-bounded
  suffix of the transcript, longest first, then inner spans by decreasing length until the cap
  (macbrow's `_span_candidates`; suffixes are the common case for spoken commands). A
  trailing-filler variant (`please`, `for me`, `okay`, `thanks` removed) is added as an extra
  candidate, never substituted for the full span, so Jev decides whether the word was
  dictation. Every candidate is a (start, end) range into the raw transcript. Dedupe
  case-insensitively, keep order of appearance, cap at 32. All candidates go in the same
  request as the other questions; macbrow spends a second round trip on this and we do not.
- **Low-confidence spans.** Below `spanConfidence` the policy waits for the committed clause. If
  the pick is still low at commit time: `web_search` proceeds with the top candidate because a
  wrong search is recoverable; `type_text` asks "type what?" instead of typing a guess.
- **URL spans.** `<word> dot <tld>` and `<word>.<tld>`; normalise "dot" to ".", "slash" to "/";
  produce `https://` URLs in code.
- **Number words.** `one`..`nine`, `first`..`ninth`, digits; resolve a numbered badge without a
  model call.
- **Kill words.** Exact `stop`, `cancel`, `never mind` as the whole utterance short-circuit to
  cancel in code before any Jev call.

## 9. Policy (`Sources/JevCore/Policy.swift`)

### 9.1 Thresholds (`Config.swift`; starting values, tuned in phase 1 on the calibration set)

Tuned by the Phase 1 lab on 2026-09-19 (README has the evidence): `isCommand` 0.35,
`complete` 0.67, and an `earlyHighConfidence` 0.85 bypass of the two-revision stability rule.

```swift
enum T {
    static let isCommand = 0.35            // was 0.50; non-commands <= 0.23, "dismiss that" 0.42
    static let intentConfidence = 0.55
    static let complete = 0.67             // was 0.60; "launch photo" 0.65 vs "scroll down" 0.69
    static let earlyHighConfidence = 0.85  // single-revision early fire above this confidence
    static let targetConfidence = 0.45
    static let targetTopProb = 0.35
    static let spanConfidence = 0.35
    static let destructive = 0.50
    static let candidateCount = 3
}
let throttleMs = 150, maxWaitMs = 400, maxInflight = 1   // one in flight + latest pending
let silenceCompleteMs = 900, payloadSilenceMs = 600
let candidateTtlMs = 8000, snapshotTtlMs = 1500
```

### 9.2 Early execution allowlist (Codex rule)

A decision computed on a non-final transcript may dispatch only these reversible actions, and only
when the intent has been the same across two consecutive revisions or its confidence is at least
`earlyHighConfidence` (lab 2026-09-19: the strict two-revision rule blocked every early fire on
short commands and never prevented a wrong one; the confidence gate caught each transient):

`open_app`, `open_site` (catalog site only, not a spoken domain), `scroll_up`, `scroll_down`,
`press_escape`.

Everything else waits for a committed clause: the recognizer's final result or `silenceCompleteMs`
of no change. `web_search`, `type_text`, and `open_site` with a spoken domain additionally wait for
the final result or `payloadSilenceMs`, so a query is never truncated. `go_back` is committed-only
because it can discard unsaved form state. `take_photo` is committed-only because it creates a
file.

### 9.3 Risk tiers

| tier | actions | rule |
|---|---|---|
| low | open_app, open_site, web_search, scroll, go_back, take_photo, press_escape | gates only |
| medium | type_text | requires a focused editable field that is not secure; else `wait("no field focused")` |
| gated | click_element, press_enter | `destructive` Noul adds a confirm step; denied labels never become candidates |
| unrepresentable | quit, empty trash, send in Messages or Mail, payments | not an intent, not a candidate |

### 9.4 Gate order

`evaluate(answers, spans, observation, silentMs, isFinal, pending) -> Decision`, pure, every gate
appended to `reasons` as (name, value, threshold, pass, note).

1. Pending confirmation and intent `confirm`/`cancel` with confidence ≥ T → act or cancel. A
   confirmation applies only to the exact pending candidate; if the snapshot changed, the pending
   candidate is dropped and the user is told.
2. `is_command` < T → **ignore**.
3. intent `none` or confidence < T → **wait**.
4. Not committed and intent not in the early-execution allowlist → **wait** with `retryInMs`.
5. Not committed and `complete` < T → **wait**.
6. Build the concrete candidate in code: bundle id, URL template, verbatim span, element token
   from the current snapshot. A missing required argument → **wait** with a human reason.
7. Target ambiguous (confidence or top probability under T on the head that matches the intent)
   → **disambiguate** with the top 2 to 3 ids having p ≥ 0.08. Heads for other operations are
   ignored entirely.
8. Gated tier and `destructive` ≥ T → **confirm**.
9. Deny list re-check on the built candidate → **ignore("denied")**.
10. **act**.

A decision computed on a stale revision (more words arrived while in flight) is treated as
non-final with `silentMs = 0`, so it can only fire allowlisted actions.

### 9.5 Utterances and continuation (`Session.swift`)

- One action per utterance. After acting, record the consumed prefix; later words in the same
  breath become a virtual utterance `<id>+<n>` only if at least two new words arrived.
- If a revision no longer starts with the consumed prefix, ignore it (the recognizer rewrote
  executed words).
- The intent epoch increments when the intent option changes between revisions; an in-flight
  decision from an older epoch is discarded.
- After every action: invalidate the snapshot and ask the speech provider to commit a segment
  boundary at the current audio time (`finalize(through:)`), which turns the volatile tail into a
  final segment without stopping the analyzer. The recognizer is not restarted; the consumed
  prefix is what makes the next command begin clean. A full session rollover happens only at a
  silence point after 45 s of continuous audio or on Stop, and the overlay shows it.
- Silence is judged from two signals together: no transcript change for the window, and audio
  level from the input tap below a threshold for the same window. A recognizer final result
  counts as an endpoint on its own. Deliberate pauses inside names and dictation are test cases.
- On `wait`, schedule a re-evaluation at `silenceCompleteMs - elapsed` so the `complete` gate is
  bypassed when the user simply stopped.
- Throttle: evaluate at most every 150 ms while revisions keep arriving, but never wait more than
  400 ms since the last evaluation, so continuous speech cannot starve the loop.

## 10. Speech (`Sources/JevMac/Speech.swift`)

`protocol SpeechProvider { var events: AsyncStream<TranscriptEvent> { get }; func start(); func finalizeSegment(); func stop() }`

Primary, decided by Phase 0 measurement on 2026-09-19: `DictationTranscriber` (macOS 26) with
`contentHints: [.shortForm]`, `reportingOptions: [.volatileResults, .frequentFinalization]`,
on a `SpeechAnalyzer` at `.userInitiated` priority. It streams a partial every 200 to 300 ms
during speech and finalizes on its own about 1.5 s after a pause. `SpeechTranscriber` is not
usable for this: without `fastResults` it emits every partial of a phrase in one burst after
the phrase ends; with `fastResults` it updates about once per second. Full numbers in the
README. The code below is kept as the general shape; `SpeechTranscriberProvider(module:
.dictation)` is the implementation.

```swift
let transcriber = SpeechTranscriber(locale: Locale(identifier: "en-US"),
                                    transcriptionOptions: [],
                                    reportingOptions: [.volatileResults],
                                    attributeOptions: [.audioTimeRange])
let analyzer = SpeechAnalyzer(modules: [transcriber])
let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber])
// AVAudioEngine input tap → AVAudioConverter to `format` → AsyncStream<AnalyzerInput>
try await analyzer.start(inputSequence: inputStream)
for try await result in transcriber.results {
    // result.isFinal == false: volatile text replaces the previous volatile text for this segment
    // result.isFinal == true : committed segment; append to the utterance and start a new segment
}
// finalizeSegment(): analyzer.finalizeAndFinish(through: lastSampleTime) then restart
```

Rules:

- One utterance spans volatile results until the analyzer finalizes on its own or the controller
  commits a boundary. Committed segments are appended to the utterance text; volatile text is
  the current tail. A forced commit calls `finalize(through:)` only through the end of the last
  result range the analyzer produced, never through audio it has not decoded: finalizing past
  decoded audio made the analyzer return punctuation-only finals for the speech that followed
  (probe runs 2 to 4). With `frequentFinalization` forced commits are rarely needed at all.
- Segments can span several commands when the pauses between them are shorter than the
  analyzer's finalization gap; the consumed-prefix rule (9.5) is what separates them, not
  finalization.
- The recognizer rewrites earlier words, not only the tail ("all right right click on" became
  "right click on that"). The consumed-prefix check in 9.5 must therefore be tolerant: match
  the last few words of the consumed prefix rather than requiring an exact string prefix.
- The input tap also reports an audio level (RMS per buffer) on the same event stream; the
  controller uses it for silence detection alongside transcript stability.
- Ensure the model with `AssetInventory.assetInstallationRequest(supporting:)` at startup; report
  "downloading" in the overlay if needed.
- Apple's newest live-audio sample targets macOS 27; do not copy it unchanged.
- Fallback provider: `SFSpeechRecognizer` with `requiresOnDeviceRecognition = true`,
  `shouldReportPartialResults = true`, one task per utterance. Same event shape.
- Phase 0 measures the volatile cadence of both providers on this Mac and picks the primary by
  data, not by default.

Permissions the app bundle needs: Microphone, Speech Recognition, Accessibility. Screen Recording
is not needed in v1. See section 15 for the bundle.

## 11. Executor and verification (`Sources/JevMac/Executor.swift`, `Verify.swift`)

Single actor, serialized queue. Every dispatch: ledger entry first, precondition recheck, action,
`ActionResult`, then `Verification` using the cheapest trustworthy evidence.

| action | implementation | fallback | verification evidence |
|---|---|---|---|
| `open_app` | `NSWorkspace.shared.openApplication(at:configuration:)` with `activates = true`; wait ≤ 3 s for frontmost | `open -a` | frontmost bundle id equals target |
| `new_note` | activate Notes, Cmd+N via `CGEvent` | `NSAppleScript`: `tell application "Notes" to make new note`, then `show` | AppleScript `count of notes` increased by one |
| `type_text` | require focused editable non-secure field; `AXUIElementSetAttributeValue(kAXValue)` when read-back matches; else `CGEvent` unicode keystrokes (Notes needs keystrokes) | none; `suspected_noop` when read-back fails | focused field value contains the text |
| `web_search` | `NSWorkspace.shared.open([url], withApplicationAt: chrome, configuration:)` using the site's search template, default Google | default browser | Chrome active tab URL contains host and encoded query |
| `open_site` | same with catalog home URL or the normalised spoken domain | | active tab URL host matches |
| `take_photo` | activate Photo Booth; AX press the element whose text is "Take Photo" | `CGEvent` Return | file count in `~/Pictures/Photo Booth Library/Pictures` increased |
| `click_element` | AX press the element token from the same snapshot id | `CGEvent` click at the frame center if press is refused | re-observation differs from the pre-action snapshot, or the element's selected state changed; else `unknown` |
| `press_enter` / `press_escape` | `CGEvent` key | | focused field or frontmost window changed; else `unknown` |
| `scroll_down` / `scroll_up` | `CGEvent` scroll wheel at the front window center; lines 3 / 15 / 200 from `scroll_amount` | | AX scroll position changed; else `unknown` |
| `go_back` | Cmd+[ when a browser is frontmost; else no-op with reason | | active tab URL changed |

Rules: never type into a secure field; never press an element whose text matches the deny list;
invalidate the snapshot after any action; `unknown` is a first-class outcome that leads to a
re-observe, never a retry of a non-idempotent action.

Verification polls its evidence with a bounded settle wait instead of reading once (jev-ultrafast
waits two animation frames or 50 ms, and up to 200 ms for autocomplete options): app activation
up to 3 s, note count up to 1 s, field value up to 500 ms, snapshot diff up to 300 ms, each polled
every 50 ms and stopping at the first change. The same bounded settle runs before every
re-observation in the Phase 6 loop, so the model is never asked to decide on a half-updated
window. A fallback in the table runs only after the
primary's verification returned `failed`, never on a missing acknowledgement: a Cmd+N whose note
count did not change gets the AppleScript path, a Cmd+N whose outcome is `unknown` gets a
re-observe first. A confirmation is bound to the exact candidate id, payload, snapshot id, and
utterance revision; any of those changing drops the pending confirmation.

Stop: a global hotkey (Control+Option+Space), the status-bar Stop, spoken "stop", or the mouse in
the top-left corner. Stop cancels the in-flight Jev task and clears the queue within 100 ms; an
already-dispatched OS action may complete and is logged as such, never claimed rolled back.

## 12. Build order and acceptance criteria

Each phase ends with its tests green and a note in README. Do not start the next phase on a red
one.

**Phase 0: toolchain, contracts, key, speech cadence.**
`Package.swift` with `JevCore`, `JevMac`, `jev-cua`, and tests; `scripts/build.sh` sets
`DEVELOPER_DIR`; `scripts/bundle.sh` assembles `JevCUA.app` and ad-hoc signs it; `jev-cua models`
and `jev-cua doctor` (permissions, model asset, key presence without printing it). Measure both
speech providers with real audio over 10 spoken sentences: volatile result cadence, revision
behavior on corrections, endpoint detection on pauses, and a segment commit followed by continued
speech without dropped words.
Acceptance: `swift build` and `swift test` pass through the Command Line Tools; the bundle launches
and shows the three permission prompts; `jev-cua models` lists `jev-latest`; one Noul request to
`jev-1.13.0` returns; a table of speech cadence numbers is in README and the primary provider is
chosen from it.

**Phase 1: decision lab (text only).**
`jev-cua lab fixtures/utterances.calibration.json` feeds every word-by-word prefix of every
command through questions and policy with `elements` empty, caches answers by request hash in
`fixtures/jev_cache.json`, and prints per prefix: intent, confidence, complete, is_command,
decision. A second file `utterances.heldout.json` with different phrasings is run once at the end
and reported separately.
Acceptance: ≥ 30 commands covering every intent and ≥ 10 non-commands including negations and
dictation that contains command words, plus "already done" cases such as "open notes" while
Notes is frontmost (hosted Jev scored 74% on already-satisfied fields in Cua's evaluation, so
code must own that check if Jev does not); final-transcript intent accuracy ≥ 90% on held-out; zero
`act` on any prefix missing its required object; all non-commands `ignore`; thresholds in
`Config.swift` updated with a comment citing the lab numbers.

**Phase 2: executors, policy, ledger, verification, typed input.**
`jev-cua say "<command>"` runs the pipeline with `isFinal = true`; `--step` prints the built
candidate and the gate table and waits for Enter before executing, and `--dry-run` stops there
(jev-ultrafast's "Choose next" pause). `scripts/demo.sh` replays the six v1 commands typed. Replay fixtures in `fixtures/transcripts/*.json` (timestamped revisions)
drive `SessionTests`.
Acceptance: all six demo commands verified on this Mac from a clean desktop; ≥ 30 replay fixtures
including repeated partials, a correction mid-flight, an appended clause after an app-open, a
negation, dictation containing command words, a stale snapshot, and a cancel during a request,
all producing zero duplicate dispatches and zero stale-target dispatches; every run writes
`runs/<ts>/events.jsonl` and `summary.json`.

**Phase 3: streaming speech, overlay, stop, spoken feedback.**
`jev-cua run` with the mic; transcript pill (non-activating borderless `NSPanel`, status-bar
level, all Spaces, ignores mouse) with the live transcript, consumed prefix dimmed, decision line
with latency, and the blocking gate on `wait`; status-bar item; stop paths.

Spoken feedback (macbrow's spoken confirmations, done on-device with `AVSpeechSynthesizer`):
- Speaks only at decision points that need the user, never for every action: a `confirm`
  request ("Say confirm to click Send"), a `disambiguate` prompt ("Which one? Say the number"),
  a `wait` that asks for a missing argument ("Open what?"), a verification `failed` or `unknown`
  outcome, and a clarifying question in goal mode. Successful low-risk actions get no speech;
  the pill shows them.
- Uses the on-device system voice, so nothing leaves the Mac. Utterances are short, one
  sentence, and a new one cuts off the previous one.
- The recognizer is muted while the app is speaking (`isSpeaking` from the synthesizer
  delegate) so its own voice is never transcribed as a command. The mute is logged.
- Toggleable: `Settings > Voice > Spoken feedback` in the status-bar menu, persisted in
  `UserDefaults` under `spokenFeedback`, default on. The CLI mirrors it with `run --speak` and
  `run --no-speak`, and `say` never speaks. A change takes effect at the next decision.
- Acceptance adds: with feedback on, a `confirm` decision is heard and the following spoken
  "confirm" is recognized and acted on once; with feedback off, the same flow is silent and the
  pill carries the prompt; five minutes of unrelated speech with feedback on still produces zero
  actions.
Acceptance over 50 spoken trials: stable clause → visible response p50 ≤ 700 ms and p95 ≤ 1500
ms; last word → dispatch median ≤ 600 ms on closed-set commands; "open the notes app and create a
new note" activates Notes on a non-final revision and creates exactly one note; five minutes of
unrelated speech produce zero actions; stop prevents new dispatch within 100 ms in an instrumented
test. Report audio-onset and command-end timings separately; do not subtract recognizer time.

**Phase 4: element targeting.**
AX walk, `elements` in state, `click_element`, numbered badges (small panels at element frames)
on `disambiguate`, spoken number resolution in code. AX fixtures captured for Notes, Photo Booth,
System Settings.
Acceptance: ≥ 90% correct target on 20 fixture commands per app; walk under 100 ms on those
apps; "take a picture of me" uses the AX press path; candidate coverage (was the right element in
the list) reported separately from selection accuracy.

**Phase 5: demo and packaging.**
README with permissions, what to say, and the numbers from phases 0 to 4. Uncut recording of the
demo script. Replay fixtures grown to ≥ 100.
Acceptance: the recording exists; the replay suite is green; `jev-cua replay runs/<ts>` re-runs
policy over logged answers with current thresholds and diffs decisions.

**Phase 6: goal mode and selective escalation.**
`TaskRunner` actor: typed goal → subgoal loop with `goal_achieved`, `blocked`, `needs_reobserve`
gates and reserved `reobserve`/`abstain` candidates; stop rules (confidence floor, two consecutive
no-ops, step and time budgets); escalation hooks behind a budget and visible in the trace: a
planner splits compound goals into subgoals with completion evidence, a writer drafts text stored
as a payload that Jev then places, a vision call interprets a window crop only when AX yields no
plausible target. Providers replaceable; default chosen by a measured comparison.

Clarification and continuation questions (macbrow's `web_goal_missing` and `browser_followup`),
asked in the same request as the gates:
- **`goal_missing`** (Choice): "If `goal` were carried out, which single required detail is most
  clearly missing or too vague to act on?" Options are the closed set of detail kinds the
  supported workflows need (`exact_dates`, `destination`, `origin`, `product`, `recipient`,
  `content`, `title`, `nothing`). When the answer is not `nothing` and the gate confidence
  clears the threshold, the runner asks one spoken or typed clarifying question naming that
  detail instead of starting the loop.
- **`followup`** (Noul, only when a previous task is recent): "Is `transcript` a follow-up,
  correction, answer, or next step for `recent_task`, rather than a new unrelated request?"
  A yes merges the utterance into the previous task's goal and continues in its context.

Writer rules, both from the reference repos:
- A generated value is reused across a stale-decision retry only while the entire writer input
  (goal, field, page context, recent history) is byte-identical, and is discarded after any
  successful mutation (jev-ultrafast). The writer's reply must parse as a JSON object with
  exactly one `text` key, or nothing is typed.
- When the goal is a question or asks for information, the writer composes the final answer from
  the last observation and the history once the loop stops (awlevin's `compose_answer`). The
  runner reports the answer together with the verification outcome and withholds it when the
  outcome is failed or unknown.
Acceptance: the ten-workflow suite below, five runs each, ≥ 90% verified per workflow with
held-out phrasing; wrong-target, false-completion, intervention, escalation counts, and cost per
completed task reported; a Jev-only versus Jev-plus-escalation comparison on the same tasks with
frozen scoring.

| workflow | completion evidence |
|---|---|
| browser search and open a specified result | query and resulting URL match |
| navigate back and forward across known pages | final URL correct, no unsaved form lost |
| fill a local fixture form with supplied literals | exact field values, no submission |
| cart task on a demo shop, stop before checkout | correct items in cart, no checkout |
| research a page and create a note | source captured, text inserted |
| create a note with title and body | exactly one note with expected contents |
| find a fixture file in Finder | correct file selected |
| move a disposable file to a folder | file at destination, nothing else changed |
| switch apps and continue a pending task | correct target, task state preserved |
| ambiguous target then clarification | user-selected candidate acted on once |

**Deferred, interfaces kept open:** Chrome DevTools Protocol observation; Vision OCR fallback;
Cua Driver as an alternate `ComputerAdapter` (spike only if AX coverage proves insufficient);
Blender and icon-only perception; a JSON-over-stdin chooser protocol for other languages; Windows
and Linux.

**Deferred, Phase 7 candidate: a local distilled scorer for the voice gates.** Cua's
`cua-s1-forms` (libs/cua-s1 in trycua/cua, MIT; 706k parameters, 2.8 MB, the jevlike
option-attention design) shows that a byte-level one-pass scorer with Jev's contract answers in
under a millisecond on a CPU and beat hosted Jev on its own narrow task. It cannot answer our
questions, but the Phase 1 lab produces exactly its training data: every word-by-word prefix,
the expected intent, and Jev's calibrated answer. Once the lab and real runs hold a few thousand
labeled prefixes, train a specialist for `intent`, `complete`, and `is_command`, evaluate it on
the held-out set with a shuffled-context control, and if it matches Jev, run it on-device (Core
ML) for the closed-set fast path with Jev kept for target heads and goal mode. The gain is
removing the network from last-word-to-dispatch, not cost.
Candidate bases for that experiment, to be compared on the same held-out set: Cua's tinyx byte
scorer (706k parameters, 3 MB, trained from scratch, needs the most data) and Laya
(github.com/NandhaKishorM/laya, Apache 2.0; ModernBERT-large, 421M parameters, about 850 MB
in fp16, pretrained so it needs far less data). Laya's own limits apply: its base checkpoints
are near chance on zero-shot typed decisions, it degrades past about 20 options, `score` is
its weakest primitive, and its published CPU latency is 193 to 464 ms, so it only beats Jev's
network hop after Core ML conversion on the Neural Engine. Neither is a zero-shot replacement
for Jev. Reviewed 2026-09-20: mizorewww/laya-coreml and mizorewww/laya-mlx (Apache 2.0,
inference-only ports validated against upstream) supply that deployment half: laya-coreml's
`convert` yields a `.mlpackage` Swift loads without Python, 11 to 14 ms per short question on
CPU+GPU, about 5 ms on a hand-built ANE graph limited to 96 tokens; laya-mlx is the Python
bench for the held-out comparison. Their prompt gives instructions and all options 192
tokens together, so our catalog questions cannot be hosted as written; only a specialist
fine-tuned upstream on the lab's labeled prefixes could be. The Swift side would need the
sequence builder, tokenizer, and calibration ported (one to two days).
The experiment, in order: (1) export the lab's labeled prefixes (every prefix, the fixture
intent, Jev's calibrated `is_command`, `complete`, `intent`, `destructive`, `followup`
answers) as training data; (2) fine-tune both bases upstream, tinyx from scratch and Laya
from the typed-decisions checkpoint; (3) score both on the held-out and realistic sets with a
shuffled-context control, against Jev's own numbers; (4) convert the Laya specialist with
laya-coreml (`.mlpackage`, CPU+GPU, then the ANE graph if the gate prompt fits 96 tokens) and
tinyx with coremltools, and measure on-device latency inside the app through a
`LocalGateDeciding` that answers only those heads, with Jev still answering the rest of the
request; (5) adopt only if held-out accuracy matches Jev and last-word-to-dispatch drops
measurably in the Phase 3 trial harness.

## 13. Testing and measurement

- `JevCoreTests`: spans, policy (every gate, mocked answers), session replay fixtures, client
  parsing of fixture responses including malformed, unknown option, 429, 529, timeout.
- `JevMacTests`: perception walk against a fake tree; executor precondition recheck with a fake AX
  layer.
- Live lab and held-out runs need the key and are skipped when it is absent.
- Run log events: transcript revision, request (state and question ids, never the key), answers,
  gate reasons, decision, ledger entry, action result, verification, timings, snapshot id. Every
  run records the model id, a hash of the question definitions, the policy version, and the app
  version, so a replay knows what produced it.
- Redaction: the bundled app logs transcripts, payloads, and element text as hashes by default;
  `--trace full` (the default for `jev-cua say`, `lab`, and development runs) keeps the text.
  Fixture files may contain full text because they are synthetic.
- The lab cache key includes the model id and the question-definition hash, so a changed
  question or a model move triggers fresh calls instead of replaying stale answers. Policy replay
  over cached answers evaluates threshold changes only; it cannot evaluate a changed question.
  Timestamps recorded: audio onset, first volatile result, stable actionable clause, request
  start and end, decision admitted, dispatch, verified visible response. Abandoned and superseded
  requests are counted.
- `summary.json`: calls, actions, input tokens, cost, request latency p50/p95, last-word→dispatch
  p50/p95, clause→response p50/p95, false fires, duplicate dispatches, unknown outcomes, and AX
  calls per snapshot (jev-ultrafast's protocol-call count was the metric that exposed its
  perception cost: 1,092 calls per task before, 101 after).
- Calibration versus held-out is a hard split from phase 1 onward. Confidence is reported as a
  distribution statistic, not as accuracy, until calibration is measured.
- Comparisons (phase 6) freeze tasks and scoring first, include recognizer and escalation costs,
  and label any playback speed on recordings.

## 14. References: what to borrow, from where

All borrowed code is JavaScript or Python and must be ported to Swift with a comment naming the
source file; keep MIT notices in `NOTICES.md`.

| Module | Borrow from | Specifically |
|---|---|---|
| `Questions.swift`, `Config.swift` | github.com/moritzkremb/jev-voice-browser `src/constants.js` | contrastive criteria, gate wording, threshold values |
| `Policy.swift` | same `src/policy.js` | gate order, reasons list, disambiguation, payload wait |
| `Session.swift` | same `src/controller.js` | one action per utterance, virtual continuation, stale-request rule, silence retry |
| `Spans.swift` | same `src/spans.js` | payload, URL, and number candidates, transcript cleaning |
| `Perception.swift` | github.com/awlevin/typesafe-computer-use `typesafe_computer_use/macos.py` (`walk_actionable`, `descendant_label`, `off_display`, `ax_press`, `ax_set_value`, `focused_field`) | pruning rules, AX helpers |
| `Perception.swift` role tables | github.com/trycua/cua PR #3914 `policy_tool.rs` | `EXCLUDED_ROLES`, `TEXT_ENTRY_ROLES`, `adopted_labels`, `__none__`, `done`/`blocked` wording |
| `Contracts.swift`, ledger, verification | `CODEX_PLAN.md` sections "Core contracts" and "Observation, execution, and recovery" | field lists, unknown-outcome semantics, precondition recheck |
| `RunLog.swift`, replay | awlevin `report.py`, `runner.py`; Moritz `scripts/demo.js`, `test/integration` | run folder, word-by-word replay |
| phase 6 gates | trycua/cua `skills/jev-use/SKILL.md`, PR #3961 `factorized.py` | reserved candidates, factorized gates |
| question style | the owner's earlier Jev project (private) | question style |
| reference only | github.com/browser-use/macOS-use `mlx_use/mac/tree.py`, `actions.py` | older AX walker; do not fork |

TypeSafe docs to keep open: `docs.typesafe.ai/concepts/how-to-build-with-system-one.md`,
`primitives/choice.md`, `primitives/noul.md`, `confidence.md`, `model-jaggedness/jev-1.13.md`,
`cookbooks/pre_parsed_value_extraction_cookbook.md`, `patterns/fan-out.md`, `api.md`, `models.md`
(1,200 requests per minute, 64k context, priced per input token).

## 15. Environment and conventions

- Machine: macOS 26.6.2 (SDK 26.5), Apple Silicon. The Xcode-selected `swift` errors on the
  unaccepted license; use `DEVELOPER_DIR=/Library/Developer/CommandLineTools` for `swift build`,
  `swift test`, `swiftc`, and `xcrun`. Swift 6.3.3 compiles AppKit and Speech (verified).
- App bundle: `scripts/bundle.sh` creates `JevCUA.app/Contents/MacOS/jev-cua` and an `Info.plist`
  with `CFBundleIdentifier io.edgeteam.jev-cua`, `LSUIElement true`,
  `NSMicrophoneUsageDescription`, `NSSpeechRecognitionUsageDescription`, then
  `codesign -s - --force`. Permissions attach to that bundle id and survive rebuilds.
- Dependencies: Apple frameworks only, plus `swift-argument-parser` for the CLI. No Yams (fixtures
  are JSON). No Cua Driver. No screenshots in v1.
- The API key lives in `.env` in this directory (ignored by git); an implementing agent must
  never read, copy, print, or source it. The app loads it itself.
  once; the app reads `.env` from its working directory or the `TYPESAFE_API_KEY` environment
  variable at launch; `jev-cua doctor` reports presence without printing it. Never log the key.
- Package managers if ever needed: `uv` for Python, `pnpm` for Node. Commit messages plain, no
  attribution lines.
- Do not use `jev-latest` in code. Do not send window titles, clipboard, or file paths to Jev.

## 16. Revision log

- 2026-09-18, first version: merge of `FABLE_PLAN.md` and `CODEX_PLAN.md` under the owner's confirmed
  decisions.
- 2026-09-18, after comparing with a colleague's combined plan, folded in: raw transcript preserved
  with span offsets and no silent filler stripping; low-confidence spans wait or clarify instead of
  taking the heuristic candidate; no recognizer restart after actions, segment boundaries committed
  in place; silence judged from transcript stability plus audio level; nameless containers pruned
  as candidates but their children kept; fallbacks only after a verified failure, never on a
  missing acknowledgement; confirmations bound to payload and revision as well as candidate and
  snapshot; redacted logs by default in the bundle with versions recorded; lab cache keyed by
  model and question hash. Not adopted from that plan: the TypeScript core with a Swift host, the Cua
  spike before the executor, and element targeting before voice (see the comparison in the chat
  transcript of 2026-09-18).
- 2026-09-19, after reviewing browser-use/jev-ultrafast and awlevin's newest commits, folded in:
  per-operation target heads (4, 7.1, 9.4); concrete answer validation (4, implemented in
  `JevClient`); semantic freshness guard and occlusion hit-test before clicks (4); bounded settle
  waits in verification and before re-observation (11); `say --step` and `--dry-run` (Phase 2);
  writer caching rule and final-answer composition (Phase 6); off-screen pressables as a separate
  head (5, 7.1); AX calls per snapshot in the summary (13); "already done" fixtures (Phase 1). Added
  a Phase 7 candidate from trycua/cua's `cua-s1-forms`: a local distilled scorer for the voice
  gates, trained on the lab's labeled prefixes.
- 2026-09-19, after reviewing milind-soni/tiptour-macos, timpratim/macbrow, and Laya, folded in:
  Electron and Chromium accessibility enablement, AX messaging timeout, and batched attribute
  reads (5); collapsing identical candidate descriptions and observer-driven snapshot refresh
  (5); installed apps as dynamic `app` options (7.1); span candidates as suffixes then inner
  spans, cap 32 (8); the richer deny-app list (2, and `Config.swift`); `goal_missing` and
  `followup` questions (Phase 6); Laya as an alternative Phase 7 base with its stated limits.
  Not adopted: Gemini Live or Gradium cloud speech, LLM-generated AppleScript tools, execution
  without confidence thresholds, Laya as a Jev replacement.
- 2026-09-19, Phase 0 measurement: `DictationTranscriber(shortForm)` chosen as the primary
  recognizer; `SpeechTranscriber` variants ruled out; forced finalization limited to decoded
  audio; prefix tolerance note added to 9.5 via section 10.
- 2026-09-19, Phase 1 complete: lab built with consumption simulation; thresholds tuned
  (`isCommand` 0.35, `complete` 0.67, `earlyHighConfidence` 0.85 bypass); `is_command` examples
  widened (q2); 100% intent on calibration and held-out, zero premature acts, zero false fires,
  every allowlisted command firing at its first fireable prefix. Jev warm p50 178 ms at ~2.9k
  tokens per decision.
- 2026-09-19, the owner's request: spoken feedback added to Phase 3, on-device, only at decision points
  that need the user, recognizer muted while speaking, toggleable in Settings and by CLI flag,
  default on.
- 2026-09-19, Phases 2–4 built: questions scoped to the first command (q4) and installed apps
  prefiltered by transcript word; AppleScript dropped from the executor (Automation prompts);
  cold-launch settle waits; TCC attribution finding → `scripts/app-run.sh` (LaunchServices launch)
  is the only way a grant applies; `UtteranceAssembler` boundaries (no close around a volatile
  tail); target heads q5 with badges and spoken-number resolution; `AXWalker` per section 5 with
  observer-driven refresh; `lab --targets` reports selection accuracy and coverage separately.
- 2026-09-19, Phase 2 acceptance: all six demo commands verified through the Developer ID signed
  bundle. Findings folded in: live frontmost read via the AX system-wide element; command_span
  examples and the joiner rule; continuation fillers dropped after a consumed command; early
  app-name gate ("launch photo" vs Photos); Photo Booth via File > Take Photo with the menu
  item's disabled state as evidence; Notes reusing an empty note counted as the postcondition;
  Developer ID signing so TCC grants survive rebuilds. Notch overlay and menu-bar icon added to
  Phase 3 at the owner's request.
- 2026-09-20, Phase 4 acceptance: 69/69 target selections over Notes, Photo Booth, and System
  Settings captures with full coverage; element descriptions carry the named container (q12).
  Live findings folded in: follow-up phrases (Phase 6 item pulled forward), noisy-room silence,
  HID-routed scrolling, glued domain tokens, the realistic utterance set (q11), Developer ID
  signing, synchronous entry point, ⌃⌥J hot key. Repo: github.com/edgeteamio/jev-cua (private).
- 2026-09-20, Phase 6: TaskRunner with the three gates, next_action with reserved reobserve and
  abstain, clause head and two-phase argument request, history tagged by clause, no-repeat rules,
  page host in browser state (a deliberate addition to section 5's privacy rule: host only),
  goal_missing and goal_compound intake, Escalating protocol with an Anthropic provider behind a
  budget, goals suite with independent evidence checks. Seven workflows hosted at 67/70.
- 2026-09-20, a live report that a note's title could be appended to but not changed: `type_text`
  gained a placement (`insert`, `replace_title`, `replace_all`) decided by a `type_placement`
  head (q22) above 0.60, else insert. Replacements select the first line or the whole value
  through `AXSelectedTextRange`, confirmed by read-back before the keystrokes (Notes applies it
  a beat after accepting it), with Cmd+A or Cmd+Up, Shift+Cmd+Right as the fallback; their
  postcondition is the old text gone, so an append is no longer "verified". An insert whose
  caret follows a word gets a leading space. The app-name gate also holds a spoken name that is
  the start of a longer one ("launch photo" before "booth"), which `complete` alone stopped
  separating under q22.
- 2026-09-20, reviewed savka777/jev-use (MIT, Swift, LLM planner over Jev grounding, or one
  Choice over every on-screen action batched at 251 because TypeSafe rejects more than 255
  options). Candidates for us, in order: menu-bar items as a `menu_item` intent with a
  `menu_target` head over the current app's enabled items filtered by the spoken words;
  repetition counts and durations parsed in code with a `counted` noul and exact repeats;
  `type_from`/`type_to` word-boundary heads for dictations beyond the span cap; `AXSelectedText`
  insertion before keystrokes (atomic replacements); a re-poke of Chromium's accessibility
  after a navigation empties its tree; a 250-option clamp in `JevClient`. Not adopted: sending
  window titles, folder names, input values and installed-app names; a generative planner ahead
  of Jev; the pointer sweep and DOM-id naming unless coverage shows a need.
- 2026-09-20, adopted three items from savka777/jev-use. (1) Menu bar as an action surface:
  a `menu_item` intent and `menu_target` head (q23) over the front app's enabled menu items,
  read in `MenuBar` with the Window/Help menus, recent-files submenus, and quoted-name items
  skipped (no titles or file names sent), filtered to the spoken words plus synonyms, executed
  by path with enabled-state and window/focus/selection evidence, and a menu deny list. (2)
  Spoken counts: `Spans.repetitions` reads "n times"/"twice", `Candidate.repeats` repeats a
  repeatable action (scroll/back/enter/escape) with per-run verification and a "performed N of
  M" report; a counted scroll uses page amount. (3) AX insertion: typing sets `AXSelectedText`
  first, read back before trusting, keystrokes as fallback, per-pid miss memo for Chrome.
  Verified live in Notes and Chrome; three labs clean. Deferred as a lab experiment: `type_from`
  /`type_to` word-boundary heads for dictations past the span cap. Noted for when the need shows:
  re-poking Chromium accessibility after a navigation empties its tree, and a 250-option clamp
  in the request builder.
- 2026-09-20, item 3 experiment (`jev-cua lab --dictation fixtures/dictations.json`,
  `Sources/jev-cua/Commands/DictationLab.swift`): on 10 dictations of 3-19 words, the span head
  and a `type_from`/`type_to` pair tied at 7/10, failing on different cases. Two findings decided
  it. The span head offered the exact text as a candidate in all 10, because the trigger-remainder
  span is the whole payload, so the 32-span cap did not bite until well past 19 words; and
  from/to's failure mode is a boundary off by one (it dropped a leading "the") that yields a
  plausible run which is not what was said, losing the verbatim guarantee the span head keeps.
  Decision: keep the span head; from/to is not adopted. Revisit only if real dictations routinely
  exceed ~30 words, where the cap would finally bite. Not deleted: the experiment command and
  `fixtures/dictations.json` stay for re-measuring after any span or question change.
- 2026-09-20, items 5 and 6 noted, not built. (5) Chromium can drop its whole accessibility tree
  after a navigation (jev-use re-sets AXManualAccessibility/AXEnhancedUserInterface after ~0.8 s
  of an empty web area); our `AX.waitForLoad` settles on child count but does not re-poke. Build
  it when a capture first shows an empty tree right after a navigation, not speculatively. (6) A
  clamp so a `Choice` never exceeds ~250 options (TypeSafe returns HTTP 400 above 255): our fixed
  catalog and caps keep us well under it today, and the `app` head is filtered by the spoken
  words, so this is a guard to add if a future head enumerates a large open set.
- 2026-09-20, live use caught the note workflow appending the body to the title line
  ("groceries milk and eggs" on one line). Cause: the goal-mode new-line rule fired only when
  the type had no named target, but Jev often names the note's text area for the body clause.
  Fix: the rule now fires when the type goes into a multi-line textarea (named target or focused
  field), single-line fields excluded; `typeInto` honors a leading newline; the insert
  postcondition is case-insensitive (Notes capitalizes a new line's first letter). The suite's
  check was too weak to catch it (substring-anywhere), so the note workflow now uses
  `value_lines_ordered` (title and body on separate lines, in order); a title-append is a false
  completion. Verified: `groceries⏎milk and eggs`, note 6/6, full suite 12/14, 0 false
  completions.
- 2026-09-21, the owner's request: repetition commands ("again", "do it again", "once more", "one
  more time") repeat the previous action. Added `repeats_action` to the follow-up head (q24),
  asked only while `last_action` is recent, so Jev separates a repeat request from narration
  ("let me read that again" does not fire). `CandidateBuilder.buildRepeat` re-runs `last_action`
  on a fresh snapshot with any spoken count applied to a repeatable action; a past-element click
  is refused. A menu command repeats by re-finding its item by path ("new tab" then "again").
  Verified live; three labs clean under q24. The "go ahead" and "never mind" confirm fixtures
  were set to minWords 1 (a pending confirmation is resolved on the first recognized confirm/
  cancel word, as "yes do it" and "cancel" already were), which the cache had masked.
- 2026-09-22, third look at awlevin/typesafe-computer-use (owner asked; main unchanged since
  2026-09-18 and reviewed twice; the 2026-09-16 X thread restates the README's cost table and
  step diagram). New and unreviewed: branch `claude/iterative-architecture-testing` (29
  commits, 2026-09-20/21) and an `AGENTS.md` branch. Candidates, ranked: (1) a screen
  signature (app, page, focused field, text lines with their row; same screen = at most one
  line in ten differs) driving stall stops (3 unchanged screens, or 2 actions already taken on
  this screen) and an `already_tried_on_this_screen` state field, replacing our history-string
  repeat guard; (2) the stop hand-off: when Jev stops low, the writer reads the screen and
  returns one move as `focus` (their 0.39 -> 0.92 example) or a `question` for the user whose
  reply joins state, bounded (10 trips, 3 questions), with a per-run "who did the work" count
  (classifier share); (3) duplicated labels carry their row mates ("in the row of 'Coldplay',
  'Oct 2'"), complementary to our container; (4) AGENTS.md rule: every ad hoc goal is proposed
  as a suite case, and this session's retitle, menu, counted-scroll, and repeat work is not in
  the goals suite yet; (5) a simulated computer driving the real loop with xfail scenarios for
  known limits, which is how they found every stop rule; (6) CI (we have none). Deferred: a
  date/clock state field with "in N days" hints (no date-dependent workflow yet), a same-state
  cost table against Opus 5 and composer reading every distinct screen (need a key), empty-
  before-keystroke (our placement head covers it).
- 2026-09-22, built items 3 and 4 from the awlevin branch review: row mates on duplicated labels
  (q25) in target heads and state; a `sessions` live suite for session mode sharing `SuiteCheck`
  with the goals suite, seven cases from this week's ad hoc work, `expected_fail` for a case that
  documents a known limit; `AGENTS.md` with the suite-per-change rules and the every-ad-hoc-goal
  rule. Found and fixed on the way: `menu_item` (q23) had split "close the window" from the
  visible close button (targets 66/69 → 69/69 with the one-wish tie rule and the no-menu click
  fallback); Chrome ignores AXPress on its menu items, so the executor sends the item's shortcut
  through the HID tap when the press changes nothing, and counts browser tabs as evidence.
  Known limit recorded: Chrome's profile picker window takes its key input. Notch: human chip
  labels, "→", brighter glowing dot.
- 2026-09-22, backlog moved to GitHub Issues (#1–#16): the stall signature and simulated
  computer (#1, #2), the writer hand-off (#3), CI (#4), the Finder and research-note
  workflows (#5, #6), Phase 3 trial scoring (#7), the Phase 5 recording (#8), Jev-only vs
  escalation (#9), date context (#10), the frontier cost table (#11), Phase 7 (#12), the Chrome
  profile-picker retest (#13), counts in goal mode (#14), composer screens (#15), Chromium
  re-poke and the option clamp (#16). This log stays the design history; Issues are the queue.
- 2026-09-23, reviewed Cua-S1-4B-0.2 (cua-ai/cua-s1-4b-0.2; trycua/cua libs/cua-s1 and
  libs/cua-bench-s1; owner asked). Two LoRA adapters (text, multimodal; Apache-2.0) on frozen
  Qwen3.5-4B: given a goal, an accessibility-tree text or a screenshot, and a closed set of
  (element, action) options, one forward pass reads option-letter logits into probabilities
  (26 options max); SFT on GUI-360/AndroidControl, then RLOO against 13 single-widget live
  environments with task-completion reward. Strong on its held-out GUI families (0.875 text,
  0.929 multimodal task accuracy; 17/18 agentic episodes, text); at chance on chess, games,
  OSWorld; torch/CUDA runtime only, no latency figures in text. Not adopted anywhere: it chooses
  among caller-enumerated options, so it does not close the no-accessibility perception gap;
  its agentic evidence is toy environments against our real-app suites; on Apple Silicon a 4B
  prefill over our state would be slower than the Jev round trip. Its benchmark's Jev rows
  (0.000-0.576) use a per-element, all-elements-correct contract whose Jev adapter is not
  public; our contract differs and our own numbers (targets 69/69, labs 100%, goals 12/14)
  stand. Worth taking: chance-corrected accuracy and ECE in the targets lab report; the
  RLOO-on-live-suites recipe and the 4B-adapter base as Phase 7 candidates (#12).
- 2026-09-28, voice-loop UX pass (owner asked for a review, then items 1a-1c, 2a-2c, 3a-3d).
  Measured from the 17 live `run` sessions in `runs/`: last word → dispatch p50 941 ms over 54
  dispatches against section 3's 600 ms; the early-fire intents met it and every intent that
  waits for a committed clause missed it by 1.6-2x. Cause: gate 4 held free text for
  `silenceCompleteMs`, so gate 5b's `payloadSilenceMs` never bound, and each commit asked Jev
  again for unchanged words. Adopted: one `commitWindowMs` per intent (the rule is the owner's; it
  keeps 900 until then); armed decisions, previewed as a ghost chip and fired on the tick that
  crosses the window from the answers in hand (once per revision; element targets are decided
  again); a status line limited to what needs the user (`Feedback`), with chatter no longer
  opening the notch; `page_host` in session state, so an unnamed search stays on the catalog
  site in front; "for"/"about" dropped from the front of a query; confirmations lapsing after
  `candidateTtlMs`, which nothing read before; chimes instead of speech for pause, resume, and
  "stop"; an outage state and a 2 s live timeout; hold-to-talk; "what can I say?", recent
  actions, and an undo limited to safe inverses. Found while verifying: a sessions run on a
  locked Mac sent a Return to `loginwindow`; nothing is decided or run while the lock screen is
  in front. Not adopted: a flat 600 ms window (6 of 118 in-phrase word gaps fell in 600-900 ms),
  a filter on follow-ups that match on-screen text (the one suspected read-aloud search matched no
  label). Policy version p2. Sessions suite 6/7 on an unlocked screen: the Chrome menu case
  passes with the profile picker closed (#13); "title then body" missed on a follow-up
  confidence of 0.54 against 0.60, a state Jev scored 0.63-0.77 on 2026-09-22.
- 2026-09-28, #18 (follow-ups after Return). The followup question never described text for a
  new line, and defined supplies_text as having no verb of its own, which list lines have. q26
  covers Return, keeps everyday verbs in list items as text, and names remarks about what someone
  did as narration. Measured on a new follow-up lab set (fixtures can now carry a focused field and
  a last action): 8/10 fired before, 10/10 after, in three fresh live runs each, with chatter
  unrelated and 0 false fires throughout. Answer validation accepts a pick within 0.02 of the
  argmax, the sum's tolerance; near-ties had dropped whole responses. Not adopted: a lower
  `followupConfidence` (where chatter was judged unrelated, supplies_text reached at most 0.47,
  0.46 on q25; a lower bar would spend that margin for every action) and a code rule for Return
  (the question was the cause, and fixing it moved every Return line above 0.87).
- 2026-09-28, focus guards. A sessions run with another window taking focus mid-case sent a
  Return decided for Notes to that window, then replaced the text of its field on a phrase decided
  with it in front. Keys and scrolls now recheck the front app before sending (section 11's
  precondition recheck, which typing and menu commands already had); the sessions suite stops a
  case whose focus moved between phrases and reports it as interrupted.
- 2026-09-28, the commit rule and two polish items. `commitWindowMs`: free text commits after
  `payloadSilenceMs` (600), everything else after `silenceCompleteMs` (900). Measured on the 35
  live search and typing commands: no pause inside a started query fell in 600-900 ms; the two in
  that band preceded the query, one with the site's own name as the span, so a query that is only
  the site's name is now refused. A site taken from the open page keeps its words in the query.
  Not adopted: a rule on span confidence, which does not separate a finished query from a growing
  one (0.85 median when fired, 0.78 while waiting). Click candidates carry a display-only label
  (chips, spoken confirmations); Chrome's profile picker is named when it swallows a menu command.
  Live after a Jev outage passed: sessions 6/6 (the Chrome case interrupted by the picker), goals
  11/12 over the six workflows without the camera, 0 false completions.
