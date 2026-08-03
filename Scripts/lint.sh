#!/usr/bin/env bash
#
# lint.sh — swift-format lint over Sources/ and Tests/.
#
# Usage:
#   Scripts/lint.sh           # advisory: prints findings, always exits 0
#   Scripts/lint.sh --strict  # gate: exits non-zero if there is any finding
#   Scripts/lint.sh --fix     # rewrite files in place
#
# Why advisory by default: formatting nits must never be the reason `make check`
# or CI goes red while a feature is mid-flight. Run `make format` to fix them, and
# switch the default to --strict once the tree is clean.
#
# swift-format ships inside recent Swift toolchains as the `swift format`
# subcommand, but not in every install (notably some Command Line Tools-only
# setups). When it is missing this script prints how to get it and exits 0 —
# a missing optional formatter must not break `make check` or CI.
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
cd "${REPO_ROOT}"

# Note: plain `[[ … ]] && x` would abort the script under `set -e` when the test
# is false, so every conditional here is written as a full if-statement.
MODE="lint"
STRICT=0
case "${1:-}" in
    --fix)    MODE="fix" ;;
    --strict) STRICT=1 ;;
    "")       ;;
    *)        printf 'usage: %s [--fix|--strict]\n' "$(basename "$0")" >&2; exit 2 ;;
esac

info() { printf '\033[34m==>\033[0m %s\n' "$*"; }
skip() { printf '\033[33mskip:\033[0m %s\n' "$*"; }

# Prefer a standalone swift-format binary, else the toolchain subcommand.
FORMAT_CMD=()
if command -v swift-format >/dev/null 2>&1; then
    FORMAT_CMD=(swift-format)
elif swift format --version >/dev/null 2>&1; then
    FORMAT_CMD=(swift format)
fi

if [[ ${#FORMAT_CMD[@]} -eq 0 ]]; then
    skip "swift-format is not available in this toolchain — skipping lint."
    printf '      Install it with:  brew install swift-format\n'
    printf '      or use a Swift 6 toolchain that bundles the `swift format` subcommand.\n'
    exit 0
fi

TARGETS=()
if [[ -d "${REPO_ROOT}/Sources" ]]; then TARGETS+=("Sources"); fi
if [[ -d "${REPO_ROOT}/Tests" ]]; then TARGETS+=("Tests"); fi
if [[ ${#TARGETS[@]} -eq 0 ]]; then
    skip "no Sources/ or Tests/ directory to lint."
    exit 0
fi

if [[ "${MODE}" == "fix" ]]; then
    info "Formatting ${TARGETS[*]} in place with: ${FORMAT_CMD[*]}"
    "${FORMAT_CMD[@]}" --in-place --recursive --parallel "${TARGETS[@]}"
    info "Formatted."
elif (( STRICT )); then
    info "Linting ${TARGETS[*]} (strict) with: ${FORMAT_CMD[*]}"
    "${FORMAT_CMD[@]}" lint --strict --recursive --parallel "${TARGETS[@]}"
    info "Lint clean."
else
    info "Linting ${TARGETS[*]} (advisory) with: ${FORMAT_CMD[*]}"
    # Without --strict, swift-format exits 0 and only prints findings.
    "${FORMAT_CMD[@]}" lint --recursive --parallel "${TARGETS[@]}"
    info "Lint finished (advisory — run 'make format' to fix any findings above)."
fi
