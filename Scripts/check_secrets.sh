#!/usr/bin/env bash
#
# check_secrets.sh — refuse to let a credential reach this PUBLIC repository.
#
# Scans every file git would consider part of the working tree (tracked files plus
# untracked files that are NOT gitignored, so .build/ and friends are skipped) for
# patterns that look like leaked credentials or machine-specific absolute paths.
#
# Usage:
#   Scripts/check_secrets.sh [--verbose]
#
# Exit status:
#   0  clean
#   1  at least one finding (each printed as path:line — rule)
#
# Deliberate design points:
#   * The findings list prints file:line and the rule name but NEVER the matched
#     text. This script runs in public CI logs; echoing the secret back would just
#     leak it a second time. Open the file yourself to inspect.
#   * Every pattern literal below is assembled from split string fragments
#     ("s""k-", "A""K""I""A", …) so the trigger text never actually occurs in this
#     file. That is what stops the scanner from reporting its own rule table —
#     no self-exclusion hack, and the script stays inside its own scan.
#   * A line that genuinely must contain a matching string can be annotated with
#     the marker below (as a comment) to be ignored.
set -euo pipefail

ALLOW_MARKER="check-secrets:allow"

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
cd "${REPO_ROOT}"

VERBOSE=0
if [[ "${1:-}" == "--verbose" || "${1:-}" == "-v" ]]; then VERBOSE=1; fi

info() { printf '\033[34m==>\033[0m %s\n' "$*"; }
fail() { printf '\033[31m%s\033[0m\n' "$*" >&2; }

# --- rule table ---------------------------------------------------------------
# Fragments keep the literal token out of this file. See the header.
F_SK="s""k-"
F_AKIA="A""K""I""A"
F_ASIA="A""S""I""A"
F_BEGIN="-----BEG""IN "
F_BEARER="[Bb]ear""er "
F_USERS="/Us""ers/"
F_GH="g""h[pousr]_"

# "name|extended-regex", checked in order.
RULES=(
    "anthropic-api-key|${F_SK}ant-[A-Za-z0-9_-]{16,}"
    "openai-api-key|${F_SK}(proj-|svcacct-)?[A-Za-z0-9_-]{24,}"
    "aws-access-key-id|(${F_AKIA}|${F_ASIA})[0-9A-Z]{16}"
    "private-key-block|${F_BEGIN}[A-Z ]*PRIVATE KEY-----"
    "bearer-token|${F_BEARER}[A-Za-z0-9._~+/=-]{24,}"
    "github-token|${F_GH}[A-Za-z0-9]{30,}"
    "absolute-user-path|${F_USERS}[A-Za-z0-9._-]{2,}/"
)

# --- collect the file list ----------------------------------------------------
FILE_LIST="$(mktemp -t voiceinput-secrets)"
cleanup() { rm -f "${FILE_LIST}"; }
trap cleanup EXIT

if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    # --cached: tracked. --others --exclude-standard: untracked but not ignored.
    # Works even in a repo with no commits yet.
    git ls-files -z --cached --others --exclude-standard > "${FILE_LIST}"
else
    find . -type f \
        -not -path './.git/*' \
        -not -path './.build/*' \
        -not -path './build/*' \
        -print0 > "${FILE_LIST}"
fi

if [[ ! -s "${FILE_LIST}" ]]; then
    info "No files to scan."
    exit 0
fi
FILE_COUNT="$(xargs -0 -n1 -- printf '%s\n' < "${FILE_LIST}" | wc -l | tr -d ' ')"
if (( VERBOSE )); then info "Scanning ${FILE_COUNT} file(s) with ${#RULES[@]} rule(s)…"; fi

# --- scan ---------------------------------------------------------------------
FINDINGS=0
REPORT="$(mktemp -t voiceinput-secrets-report)"
cleanup() { rm -f "${FILE_LIST}" "${REPORT}"; }

for rule in "${RULES[@]}"; do
    name="${rule%%|*}"
    pattern="${rule#*|}"

    # -I skips binary files, -H forces the filename prefix even for a single file
    # (xargs may hand grep exactly one path in the last batch).
    hits="$(xargs -0 grep -HInE -e "${pattern}" -- < "${FILE_LIST}" 2>/dev/null || true)"
    # Written as an if, not `[[ … ]] && continue`: the latter would abort the
    # whole script under `set -e` whenever the test is false.
    if [[ -z "${hits}" ]]; then continue; fi

    while IFS= read -r hit; do
        if [[ -z "${hit}" ]]; then continue; fi
        case "${hit}" in
            *"${ALLOW_MARKER}"*) continue ;;
        esac
        # Strip the matched content; keep only path:line.
        location="$(printf '%s' "${hit}" | cut -d: -f1,2)"
        printf '  %s — %s\n' "${location}" "${name}" >> "${REPORT}"
        FINDINGS=$((FINDINGS + 1))
    done <<< "${hits}"
done

if (( FINDINGS > 0 )); then
    fail "check_secrets: ${FINDINGS} potential secret(s) or machine-specific path(s) found:"
    sort -u "${REPORT}" >&2
    cat >&2 <<EOF

  This repository is PUBLIC. Nothing above may be committed.
    * API keys belong in the macOS Keychain (service io.github.voiceinput.VoiceInput),
      entered by the user in Settings — never in a file, never in a test fixture.
    * Absolute home-directory paths break every other machine; derive paths from
      \${BASH_SOURCE[0]} in scripts, or Bundle/FileManager in Swift.
  If a match is genuinely safe, append the comment marker "${ALLOW_MARKER}" to that line.
EOF
    exit 1
fi

info "check_secrets: clean (${FILE_COUNT} files, ${#RULES[@]} rules)."
