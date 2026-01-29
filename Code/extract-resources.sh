#!/usr/bin/env bash
set -euo pipefail

# extract-resources.sh
# Extract Moodle activity links from a saved course HTML page.
# Self-resolving: writes outputs relative to the script directory.

# ---------------------------------------------------------------------
# Block 0: Resolve paths
# What: Determine the project root as the directory this script lives in.
# Why: Allows running the script from anywhere without relying on $PWD.
# ---------------------------------------------------------------------
PROJECT_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
OUT_FILE="${PROJECT_ROOT}/resource_urls.txt"
BASE="https://solomon.ugle.org.uk"
BACKUP_DIR="${PROJECT_ROOT}/.backups"

# ---------------------------------------------------------------------
# Block 0.1: Helpers
# What: Standard error/usage functions.
# Why: Consistent operator feedback and clean exits.
# ---------------------------------------------------------------------
die() {
  echo
  echo "[✗] $1"
  echo
  exit 1
}

usage() {
  cat <<EOF
Usage:
  $(basename "$0") [--all] /path/to/CoursePage.html

Modes:
  (default)  Extract only Moodle "resource" links:
             /mod/resource/view.php?id=####

  --all      Also extract:
             /mod/page/view.php?id=####
             /mod/url/view.php?id=####

Output:
  ${OUT_FILE}

Notes:
  - Handles absolute, relative, and escaped URLs.
  - Canonicalizes output to ${BASE}/mod/<type>/view.php?id=#### (deduped).
EOF
}

# ---------------------------------------------------------------------
# Block 1: Parse arguments
# What: Support optional flags + required HTML path.
# Why: Lets you expand beyond PDFs later (pages/urls) without new tools.
# ---------------------------------------------------------------------
MODE_ALL=0
HTML_PATH=""

if [[ "${1:-}" == "--all" ]]; then
  MODE_ALL=1
  shift
fi

HTML_PATH="${1:-}"
if [[ -z "${HTML_PATH}" ]]; then
  usage
  die "No HTML file provided."
fi

if [[ ! -f "${HTML_PATH}" ]]; then
  die "HTML file not found: ${HTML_PATH}"
fi

# ---------------------------------------------------------------------
# Block 2: Backup existing output
# What: Preserve previous resource_urls.txt with timestamp suffix.
# Why: Prevents accidental loss when iterating/debugging.
# ---------------------------------------------------------------------
if [[ -f "${OUT_FILE}" ]]; then
  TS="$(date +%Y%m%d-%H%M%S)"
  mkdir -p "${BACKUP_DIR}"
  cp -f "${OUT_FILE}" "${BACKUP_DIR}/resource_urls.txt.${TS}.bak"
  echo "[i] Backed up existing $(basename "${OUT_FILE}") -> ${BACKUP_DIR}/resource_urls.txt.${TS}.bak"
fi

# ---------------------------------------------------------------------
# Block 3: Temporary output handling
# What: Use mktemp for atomic write, trap cleanup on exit.
# Why: Avoids partial/corrupt outputs if the script is interrupted.
# ---------------------------------------------------------------------
TMP_OUT="$(mktemp)"
cleanup() { rm -f "${TMP_OUT}"; }
trap cleanup EXIT

# ---------------------------------------------------------------------
# Block 4: Extract links (robust)
# What:
#   - Extract absolute + relative + escaped occurrences of:
#       /mod/resource/view.php?id=####
#       /mod/page/view.php?id=####
#       /mod/url/view.php?id=####
# Why:
#   - Saved Moodle HTML contains a mix of absolute/relative links and JS strings.
#   - We canonicalize everything into clean absolute URLs and dedupe.
# ---------------------------------------------------------------------

# Build a single GREP pattern that matches:
#  - escaped absolute:  https:\/\/solomon...\/mod\/resource\/view.php\?id=123
#  - absolute:          https://solomon.../mod/resource/view.php?id=123
#  - relative:          /mod/resource/view.php?id=123
#
# Important: we capture ONLY the "id=digits" part (ignore &redirect=1 etc)
# by matching id=\d+ and stopping there.

RESOURCE_ANY='(?:https:\\/\\/solomon\.ugle\.org\.uk\\/)?mod\\/resource\\/view\.php\\?id=\\d+|https:\/\/solomon\.ugle\.org\.uk\/mod\/resource\/view\.php\?id=\d+|\/mod\/resource\/view\.php\?id=\d+'
PAGE_ANY='(?:https:\\/\\/solomon\.ugle\.org\.uk\\/)?mod\\/page\\/view\.php\\?id=\\d+|https:\/\/solomon\.ugle\.org\.uk\/mod\/page\/view\.php\?id=\d+|\/mod\/page\/view\.php\?id=\d+'
URL_ANY='(?:https:\\/\\/solomon\.ugle\.org\.uk\\/)?mod\\/url\\/view\.php\\?id=\\d+|https:\/\/solomon\.ugle\.org\.uk\/mod\/url\/view\.php\?id=\d+|\/mod\/url\/view\.php\?id=\d+'

if [[ "${MODE_ALL}" -eq 1 ]]; then
  echo "[i] Mode: --all (resource + page + url)"
  GREP_RE="${RESOURCE_ANY}|${PAGE_ANY}|${URL_ANY}"
else
  echo "[i] Mode: resource only"
  GREP_RE="${RESOURCE_ANY}"
fi

# Extraction pipeline:
# 1) grep matches (may be escaped)
# 2) unescape \/ -> /
# 3) strip leading origin if present (we’ll re-add BASE)
# 4) ensure leading slash
# 5) canonicalize to BASE + path
# 6) sort unique
grep -oP "${GREP_RE}" "${HTML_PATH}" \
  | sed 's#\\/#/#g' \
  | sed 's#^https\?://solomon\.ugle\.org\.uk##' \
  | sed 's#^mod/#/mod/#' \
  | sed "s#^#${BASE}#; s#${BASE}${BASE}#${BASE}#g" \
  | sort -u \
  > "${TMP_OUT}"

COUNT="$(wc -l < "${TMP_OUT}" | tr -d ' ')"
if [[ "${COUNT}" -eq 0 ]]; then
  die "No matching URLs found. Are you sure this is the saved course page HTML?"
fi

# ---------------------------------------------------------------------
# Block 5: Write output atomically
# What: Move tmp file into place.
# Why: Guarantees OUT_FILE is complete or not written at all.
# ---------------------------------------------------------------------
mv -f "${TMP_OUT}" "${OUT_FILE}"
trap - EXIT

echo "[✓] Extracted ${COUNT} unique URL(s)"
echo "[i] Wrote: ${OUT_FILE}"

# ---------------------------------------------------------------------
# Block 6: Preview
# What: Show first 10 extracted URLs.
# Why: Quick human validation before running downloads.
# ---------------------------------------------------------------------
echo
echo "---- Preview (first 10) ----"
head -n 10 "${OUT_FILE}"
echo "----------------------------"
