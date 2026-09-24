#!/bin/bash
# Replay the v1 demo script as typed commands, one `say` per line, with pauses between them.
# Runs through the bundle (scripts/app-run.sh) so Accessibility applies and verifications work.
# Run from a clean desktop with Notes, Chrome, and Photo Booth installed. Extra args go to `say`
# (e.g. --dry-run, --step).
set -uo pipefail
cd "$(dirname "$0")/.."
[ -d dist/JevCUA.app ] || bash scripts/bundle.sh
EXTRA="${@:-}"
run() { echo; echo "▶ $1"; scripts/app-run.sh say "$1" $EXTRA; sleep "${2:-1.5}"; }
run "open the notes app and create a new note" 1.5
run "make the title say hello" 1.0
run "open chrome" 1.5
run "google search norbert wiener" 2.0
run "open x dot com" 2.0
run "take a picture of me" 1.0
