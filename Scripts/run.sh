#!/usr/bin/env bash
#
# run.sh — build the .app bundle and launch it, optionally streaming its logs.
#
# Usage:
#   Scripts/run.sh [--debug] [--no-logs] [-- <extra build_app.sh args>]
#
# The app is a menu-bar agent (LSUIElement), so nothing appears in the Dock —
# look for the icon in the right-hand side of the menu bar.
#
# Logs: the app should log via os.Logger with subsystem "io.github.voiceinput".
# This script tails that subsystem with `log stream`, which is the only way to see
# output from a bundled .app (its stdout goes nowhere). Ctrl-C stops the tail; the
# app keeps running — quit it from its menu.
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
cd "${REPO_ROOT}"

APP_BUNDLE="${REPO_ROOT}/build/VoiceInput.app"
LOG_SUBSYSTEM="io.github.voiceinput"

info() { printf '\033[34m==>\033[0m %s\n' "$*"; }
die() { printf '\033[31merror:\033[0m %s\n' "$*" >&2; exit 1; }

BUILD_ARGS=()
STREAM_LOGS=1
while [[ $# -gt 0 ]]; do
    case "$1" in
        --no-logs) STREAM_LOGS=0 ;;
        --)        shift; BUILD_ARGS+=("$@"); break ;;
        *)         BUILD_ARGS+=("$1") ;;
    esac
    shift
done

"${SCRIPT_DIR}/build_app.sh" ${BUILD_ARGS[@]+"${BUILD_ARGS[@]}"}

[[ -d "${APP_BUNDLE}" ]] || die "bundle missing: ${APP_BUNDLE}"

# Quit a previous instance so the freshly built binary is the one running.
if pgrep -x "VoiceInput" >/dev/null 2>&1; then
    info "Quitting the running VoiceInput instance…"
    osascript -e 'quit app "VoiceInput"' >/dev/null 2>&1 || pkill -x "VoiceInput" || true
    # Give it a moment to release the hotkey and audio device.
    for _ in 1 2 3 4 5 6 7 8 9 10; do
        pgrep -x "VoiceInput" >/dev/null 2>&1 || break
        sleep 0.2
    done
fi

info "Launching ${APP_BUNDLE}…"
open "${APP_BUNDLE}" || die "open failed. Try running the binary directly: ${APP_BUNDLE}/Contents/MacOS/VoiceInput"
info "Menu-bar-only app — look for the icon in the menu bar, not the Dock."

if (( STREAM_LOGS )); then
    if command -v log >/dev/null 2>&1; then
        info "Streaming logs (subsystem == \"${LOG_SUBSYSTEM}\"). Ctrl-C stops the tail, not the app."
        # `log stream` needs no special privileges for another process's public
        # logs. Any os_log entry marked .private (transcripts must be) shows as
        # <private> here — that is deliberate, see docs/SECURITY.md.
        exec log stream --style compact --level debug \
            --predicate "subsystem == \"${LOG_SUBSYSTEM}\""
    else
        info "'log' not available; skipping the log stream."
    fi
fi
