# AGENTS.md

Rules for agents working in this repository. The design is `NEW_COMBINED_PLAN.md`; the
status of each phase is in `README.md`.

## Ground rules

- Jev selects; code computes. Every argument an action needs is a verbatim span, a catalog
  entry, or a number code read from the transcript. No free text reaches an action unless the
  escalation writer produced it, under budget.
- Nothing about window titles, clipboard, file paths, full URLs, or names in quoted menu items
  is sent to Jev. The page host and the front app's name are the only identifying facts.
- Every action is verified from evidence, never from the dispatch succeeding. "Unknown" is a
  result; a repeat of an unknown-outcome action is never automatic.
- Build with `scripts/build.sh`, test with `scripts/test.sh`, run anything that needs
  permissions through `scripts/app-run.sh`. No third-party dependencies.

## Suites

| suite | what it holds | command | when to run |
|---|---|---|---|
| unit + replay | policy gates, spans, session cadence (109 scenarios), goal loop against fakes | `scripts/test.sh` | every change |
| labs | intent, app, site, span selection on every word-by-word prefix; premature and false fires must be 0 | `scripts/jev-cua lab --installed-apps [--heldout …] [--fixtures …]` | any change to `Questions.swift`, `Policy.swift`, `Spans.swift`, `Transcript.swift`, `Config.swift` (the model sees something new); put the numbers in the commit |
| targets | element selection over captured trees | `scripts/jev-cua lab --targets fixtures/targets` | any change to element descriptions or target heads |
| sessions | session mode live: follow-ups, repeats, placements, menu commands | `scripts/app-run.sh sessions fixtures/sessions/session.json` | any change to `Executor.swift`, `AXWalker.swift`, `Perception.swift`, `Session.swift`, or a question they feed |
| goals | goal mode live: seven workflows, two phrasings each, independent evidence | `scripts/app-run.sh goals fixtures/goals/phase6.json` | any change to `TaskRunner.swift`, `Goal.swift`, `Escalation.swift`, or the executor |

The live suites need the screen unlocked and the display awake; a locked screen blocks every
run as `loginwindow`.

## Every ad hoc goal is a candidate case

Whenever a phrase sequence or goal is tried outside the suites (`say "…" "…"`, `goal "…"`), end
the work by proposing how to keep it:

1. A case for `fixtures/sessions/session.json` (session mode) or a workflow for
   `fixtures/goals/phase6.json` (goal mode), with the setup, the phrases or goal, and the
   evidence check that proves the outcome — a check that would have failed on the bug, not
   one that passes on the fix alone.
2. For a decision that was wrong or just fixed, the lab fixture (calibration, held-out,
   realistic, or a target capture) that pins it.

Propose; do not add silently. A case the user rejects is not added. A case the user accepts
goes in the same change as the fix it protects.

A lower number is a finding, not a failure to hide. Report it with the run folder.

## Backlog

Open work lives in GitHub Issues on `edgeteamio/jev-cua`, labelled `phase:N` and `kind:feature|bug|experiment|measurement|infra`. `NEW_COMBINED_PLAN.md` is the design record and its revision log the history, not the queue. A commit that finishes an issue says `closes #N`; a finding that is not being fixed now becomes an issue, not a note in a file.
