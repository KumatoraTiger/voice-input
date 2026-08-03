#!/usr/bin/env bash
#
# test.sh — build every target, then run the unit tests.
#
# Usage:
#   Scripts/test.sh [--release] [extra swift test args…]
#
# `swift test` only builds what the test target depends on (VoiceInputCore), so
# the full `swift build` first is what actually catches breakage in
# VoiceInputPlatform and VoiceInputApp.
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
cd "${REPO_ROOT}"

CONFIG="${CONFIG:-debug}"
EXTRA=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        --release) CONFIG="release" ;;
        --debug)   CONFIG="debug" ;;
        *)         EXTRA+=("$1") ;;
    esac
    shift
done

info() { printf '\033[34m==>\033[0m %s\n' "$*"; }

# Mirror build_app.sh's SDK detection so tests compile the same code paths the
# app bundle will. See Package.swift / docs/ENGINES.md.
SDK_VERSION="$(xcrun --show-sdk-version 2>/dev/null || echo "unknown")"
SDK_MAJOR="${SDK_VERSION%%.*}"
if [[ "${VOICEINPUT_SPEECH_ANALYZER:-}" != "1" ]] \
    && [[ "${SDK_MAJOR}" =~ ^[0-9]+$ ]] && (( SDK_MAJOR >= 26 )); then
    export VOICEINPUT_SPEECH_ANALYZER=1
fi
info "macOS SDK ${SDK_VERSION} · SPEECH_ANALYZER=${VOICEINPUT_SPEECH_ANALYZER:-0} · config ${CONFIG}"

info "Building all targets…"
swift build -c "${CONFIG}"

info "Running tests…"
swift test -c "${CONFIG}" ${EXTRA[@]+"${EXTRA[@]}"}

info "OK"
