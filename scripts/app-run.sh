#!/bin/bash
# Run a jev-cua subcommand through LaunchServices so macOS attributes Microphone, Speech and
# Accessibility to JevCUA.app itself (a binary started from a shell is attributed to the
# terminal). Output is relayed from temp files; the exit code is the app's.
#   scripts/app-run.sh say "open chrome"
#   scripts/app-run.sh doctor --prompt
set -uo pipefail
cd "$(dirname "$0")/.."
APP=dist/JevCUA.app
[ -d "$APP" ] || { echo "no $APP; run scripts/bundle.sh" >&2; exit 2; }
OUT=$(mktemp -t jevcua-out); ERR=$(mktemp -t jevcua-err)
open -n -W --stdout "$OUT" --stderr "$ERR" "$APP" --args "$@" --cwd "$PWD"
CODE=$?
cat "$OUT"; cat "$ERR" >&2
rm -f "$OUT" "$ERR"
exit $CODE
