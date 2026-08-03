#!/usr/bin/env bash
#
# build_app.sh — assemble build/VoiceInput.app from the SwiftPM executable.
#
# Xcode is not required (and is not installed on the reference machine): this
# script only needs the Command Line Tools + a Swift 6 toolchain. Never use
# xcodebuild in this repo.
#
# Usage:
#   Scripts/build_app.sh [--debug] [--install] [--hardened] [--no-sign]
#
# Options:
#   --debug      build the debug configuration (same as CONFIG=debug)
#   --install    copy the finished bundle to /Applications (replaces any existing)
#   --hardened   sign with the Hardened Runtime + Resources/VoiceInput.entitlements
#                (only meaningful with a real Developer ID in $CODESIGN_IDENTITY)
#   --no-sign    skip code signing entirely (the app will not be able to keep
#                microphone/accessibility grants — for CI smoke tests only)
#
# Environment:
#   CONFIG=debug|release        build configuration (default: release)
#   CODESIGN_IDENTITY="..."     signing identity; when unset an ad-hoc signature
#                               is used (see the warning printed at the end)
#   INSTALL_DIR=/path           where --install copies the bundle
#                               (default /Applications; overridable so the
#                               install path can be exercised in a test)
#   VOICEINPUT_SPEECH_ANALYZER  set to 1 to force the SpeechAnalyzer code path on;
#                               normally detected from the SDK version below
set -euo pipefail

# --- locate the repository root, so the script works from any cwd -------------
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
cd "${REPO_ROOT}"

APP_NAME="VoiceInput"
PRODUCT="VoiceInputApp"          # SwiftPM product name
BUNDLE_ID="io.github.voiceinput.VoiceInput"
BUILD_DIR="${REPO_ROOT}/build"
APP_BUNDLE="${BUILD_DIR}/${APP_NAME}.app"
DEFAULT_VERSION="0.1.0"

CONFIG="${CONFIG:-release}"
DO_INSTALL=0
HARDENED=0
DO_SIGN=1

die() { printf '\033[31merror:\033[0m %s\n' "$*" >&2; exit 1; }
info() { printf '\033[34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[33mwarning:\033[0m %s\n' "$*" >&2; }

while [[ $# -gt 0 ]]; do
    case "$1" in
        --debug)    CONFIG="debug" ;;
        --release)  CONFIG="release" ;;
        --install)  DO_INSTALL=1 ;;
        --hardened) HARDENED=1 ;;
        --no-sign)  DO_SIGN=0 ;;
        # Print the header comment block (everything between the shebang and the
        # first line of code) rather than a hardcoded line range, so editing the
        # header cannot silently truncate --help.
        -h|--help)
            awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' \
                "${BASH_SOURCE[0]}"
            exit 0
            ;;
        *)          die "unknown option: $1 (try --help)" ;;
    esac
    shift
done

[[ "${CONFIG}" == "debug" || "${CONFIG}" == "release" ]] \
    || die "CONFIG must be 'debug' or 'release', got '${CONFIG}'"

command -v swift >/dev/null 2>&1 \
    || die "swift not found. Install the Xcode Command Line Tools: xcode-select --install"

# --- SpeechAnalyzer gating ----------------------------------------------------
# Apple's SpeechAnalyzer API only exists in the macOS 26 SDK. Package.swift turns
# the VOICEINPUT_SPEECH_ANALYZER env var into the SPEECH_ANALYZER compilation
# condition; the adapter in VoiceInputPlatform is wrapped in #if SPEECH_ANALYZER.
SDK_VERSION="$(xcrun --show-sdk-version 2>/dev/null || echo "unknown")"
SDK_MAJOR="${SDK_VERSION%%.*}"

if [[ "${VOICEINPUT_SPEECH_ANALYZER:-}" == "1" ]]; then
    info "SpeechAnalyzer: forced ON via VOICEINPUT_SPEECH_ANALYZER=1 (SDK ${SDK_VERSION})"
elif [[ "${SDK_MAJOR}" =~ ^[0-9]+$ ]] && (( SDK_MAJOR >= 26 )); then
    export VOICEINPUT_SPEECH_ANALYZER=1
    info "SpeechAnalyzer: ON — macOS SDK ${SDK_VERSION} (>= 26) provides the API."
else
    info "SpeechAnalyzer: OFF — macOS SDK ${SDK_VERSION} predates 26, so the API does"
    info "                not exist to compile against. The app still works; the"
    info "                'Apple SpeechAnalyzer' engine is reported as unavailable."
    info "                See docs/ENGINES.md."
fi

# --- build --------------------------------------------------------------------
info "Building ${PRODUCT} (${CONFIG})…"
swift build -c "${CONFIG}" --product "${PRODUCT}"

BIN_DIR="$(swift build -c "${CONFIG}" --product "${PRODUCT}" --show-bin-path)"
BIN_PATH="${BIN_DIR}/${PRODUCT}"
[[ -f "${BIN_PATH}" ]] || die "built binary not found at ${BIN_PATH}"

# --- version ------------------------------------------------------------------
# git describe when there are tags/commits, otherwise the hardcoded default.
RAW_VERSION="$(git -C "${REPO_ROOT}" describe --tags --always --dirty 2>/dev/null || true)"
if [[ -z "${RAW_VERSION}" ]]; then
    SHORT_VERSION="${DEFAULT_VERSION}"
    BUILD_VERSION="${DEFAULT_VERSION}"
else
    BUILD_VERSION="${RAW_VERSION#v}"
    # CFBundleShortVersionString must be 1-3 dot-separated integers.
    SHORT_VERSION="$(printf '%s' "${BUILD_VERSION}" \
        | sed -n 's/^\([0-9][0-9]*\(\.[0-9][0-9]*\)\{0,2\}\).*$/\1/p')"
    [[ -n "${SHORT_VERSION}" ]] || SHORT_VERSION="${DEFAULT_VERSION}"
fi

# --- assemble the bundle ------------------------------------------------------
info "Assembling ${APP_BUNDLE} (version ${SHORT_VERSION}, build ${BUILD_VERSION})…"
rm -rf "${APP_BUNDLE}"
mkdir -p "${APP_BUNDLE}/Contents/MacOS" "${APP_BUNDLE}/Contents/Resources"

cp "${BIN_PATH}" "${APP_BUNDLE}/Contents/MacOS/${APP_NAME}"
chmod +x "${APP_BUNDLE}/Contents/MacOS/${APP_NAME}"

# Classic package marker. Harmless, and some tooling still looks for it.
printf 'APPL????' > "${APP_BUNDLE}/Contents/PkgInfo"

PLIST_TEMPLATE="${REPO_ROOT}/Resources/Info.plist"
[[ -f "${PLIST_TEMPLATE}" ]] || die "missing template: ${PLIST_TEMPLATE}"
sed -e "s|__VOICEINPUT_SHORT_VERSION__|${SHORT_VERSION}|g" \
    -e "s|__VOICEINPUT_BUILD_VERSION__|${BUILD_VERSION}|g" \
    "${PLIST_TEMPLATE}" > "${APP_BUNDLE}/Contents/Info.plist"

# Fail loudly rather than shipping a bundle macOS will silently refuse to launch.
plutil -lint "${APP_BUNDLE}/Contents/Info.plist" >/dev/null \
    || die "rendered Info.plist is not valid; check Resources/Info.plist"
if grep -q "__VOICEINPUT_" "${APP_BUNDLE}/Contents/Info.plist"; then
    die "unsubstituted __VOICEINPUT_*__ placeholder left in Info.plist"
fi

# Loose resources (icon, assets…) get copied verbatim. Info.plist and the
# entitlements are handled above; README.md documents the folder for humans and
# has no business inside a shipped bundle.
shopt -s nullglob
for res in "${REPO_ROOT}/Resources"/*; do
    base="$(basename "${res}")"
    case "${base}" in
        Info.plist|*.entitlements|README.md) continue ;;
    esac
    cp -R "${res}" "${APP_BUNDLE}/Contents/Resources/"
done

# SwiftPM emits per-target resource bundles next to the binary; the app looks for
# them beside its executable, i.e. in Contents/MacOS.
for pkg_bundle in "${BIN_DIR}"/*.bundle; do
    cp -R "${pkg_bundle}" "${APP_BUNDLE}/Contents/MacOS/"
done
shopt -u nullglob

# --- code signing -------------------------------------------------------------
SIGN_MODE="none"
if (( DO_SIGN )); then
    # --deep so the nested SwiftPM resource bundles get signed too.
    CODESIGN_ARGS=(--force --deep)
    if (( HARDENED )); then
        ENTITLEMENTS="${REPO_ROOT}/Resources/VoiceInput.entitlements"
        [[ -f "${ENTITLEMENTS}" ]] || die "missing ${ENTITLEMENTS}"
        CODESIGN_ARGS+=(--options runtime --entitlements "${ENTITLEMENTS}")
    fi

    if [[ -n "${CODESIGN_IDENTITY:-}" ]]; then
        SIGN_MODE="identity"
        info "Code signing with identity: ${CODESIGN_IDENTITY}"
        codesign "${CODESIGN_ARGS[@]}" --sign "${CODESIGN_IDENTITY}" "${APP_BUNDLE}" \
            || die "codesign failed. Check that '${CODESIGN_IDENTITY}' exists: security find-identity -v -p codesigning"
    else
        SIGN_MODE="adhoc"
        info "Code signing ad-hoc (no CODESIGN_IDENTITY set)…"
        # --timestamp=none: an ad-hoc signature is never notarized, and asking for
        # a secure timestamp would make the build depend on Apple's server.
        codesign "${CODESIGN_ARGS[@]}" --timestamp=none --sign - "${APP_BUNDLE}" \
            || die "ad-hoc codesign failed"
    fi
    codesign --verify --verbose=1 "${APP_BUNDLE}" >/dev/null 2>&1 \
        || warn "codesign --verify reported a problem; the app may still run."
else
    warn "Skipping code signing (--no-sign)."
fi

info "Built ${APP_BUNDLE}"
printf '    bundle id : %s\n' "${BUNDLE_ID}"
printf '    version   : %s (%s)\n' "${SHORT_VERSION}" "${BUILD_VERSION}"
printf '    config    : %s\n' "${CONFIG}"
printf '    speech    : SPEECH_ANALYZER=%s\n' "${VOICEINPUT_SPEECH_ANALYZER:-0}"

if [[ "${SIGN_MODE}" == "adhoc" ]]; then
    cat <<'ADHOC'

  NOTE: this build is ad-hoc signed.
  An ad-hoc signature has no stable identity, so macOS treats every rebuild as a
  different app: microphone, speech-recognition and accessibility permissions are
  forgotten and re-prompted after each `make app`.

  To keep permissions across rebuilds, create a free self-signed code-signing
  certificate once:
    Keychain Access → Certificate Assistant → Create a Certificate…
      Name: VoiceInput Self Signed
      Identity Type: Self Signed Root
      Certificate Type: Code Signing
  then build with:
    CODESIGN_IDENTITY="VoiceInput Self Signed" make app
  (See README.md → 「アドホック署名の注意」.)
ADHOC
fi

# --- optional install ---------------------------------------------------------
if (( DO_INSTALL )); then
    INSTALL_DIR="${INSTALL_DIR:-/Applications}"
    [[ -d "${INSTALL_DIR}" ]] || die "INSTALL_DIR does not exist: ${INSTALL_DIR}"
    DEST="${INSTALL_DIR}/${APP_NAME}.app"
    info "Installing to ${DEST}…"
    if [[ -e "${DEST}" ]]; then
        rm -rf "${DEST}" || die "could not remove ${DEST} (is the app running?)"
    fi
    cp -R "${APP_BUNDLE}" "${DEST}" || die "could not copy to /Applications"
    printf '    installed: %s -> %s\n' "${APP_BUNDLE}" "${DEST}"
    printf '    launch it with: open -a %s\n' "${APP_NAME}"
fi
