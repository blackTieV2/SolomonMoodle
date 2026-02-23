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
: "${BASE_URL:?BASE_URL must be set by the launcher script}"
BACKUP_DIR="${PROJECT_ROOT}/.backups"
PLUGINS_DIR="${PROJECT_ROOT}/plugins/modules"

BASE_HOST="${BASE_URL#https://}"
BASE_HOST="${BASE_HOST#http://}"
BASE_HOST_ESCAPED="$(printf '%s' "${BASE_HOST}" | sed 's/[.[\^$*+?(){|]/\\&/g')"

# ---------------------------------------------------------------------
# Block 0.2: Module registration + plugins
# What: Allow new Moodle module types to be registered via plugins.
# ---------------------------------------------------------------------
declare -A MODULE_PATTERNS
MODULE_NAMES=()
DEFAULT_MODULES=()

register_module() {
  local name="$1"
  local pattern="$2"
  local include_default="${3:-0}"

  if [[ -z "${name}" || -z "${pattern}" ]]; then
    die "register_module requires a name and pattern."
  fi

  MODULE_PATTERNS["${name}"]="${pattern}"
  MODULE_NAMES+=("${name}")
  if [[ "${include_default}" == "1" ]]; then
    DEFAULT_MODULES+=("${name}")
  fi
}

# Built-in modules
register_module "resource" "mod\\/resource\\/view\\.php\\?id=\\d+" 1
register_module "page" "mod\\/page\\/view\\.php\\?id=\\d+" 0
register_module "url" "mod\\/url\\/view\\.php\\?id=\\d+" 0

if [[ -d "${PLUGINS_DIR}" ]]; then
  for plugin in "${PLUGINS_DIR}"/*.sh; do
    [[ -f "${plugin}" ]] || continue
    # shellcheck source=/dev/null
    source "${plugin}"
  done
fi

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
  $(basename "$0") [--all] [--modules <list>] /path/to/CoursePage.html

Modes:
  (default)  Extract only Moodle "resource" links:
             /mod/resource/view.php?id=####

  --all      Also extract:
             /mod/page/view.php?id=####
             /mod/url/view.php?id=####

  --modules  Comma-separated list of module names to extract.

Output:
  ${OUT_FILE}

Notes:
  - Handles absolute, relative, and escaped URLs.
  - Canonicalizes output to ${BASE_URL}/mod/<type>/view.php?id=#### (deduped).
  - Override base with BASE_URL=https://your-moodle.example
EOF
}

# ---------------------------------------------------------------------
# Block 1: Parse arguments
# What: Support optional flags + required HTML path.
# Why: Lets you expand beyond PDFs later (pages/urls) without new tools.
# ---------------------------------------------------------------------
MODE_ALL=0
HTML_PATH=""
MODULES=""

while [[ $# -gt 0 ]]; do
  case "${1:-}" in
    --all)
      MODE_ALL=1
      shift
      ;;
    --modules)
      MODULES="${2:-}"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      if [[ -z "${HTML_PATH}" ]]; then
        HTML_PATH="${1}"
        shift
      else
        usage
        die "Unexpected argument: ${1}"
      fi
      ;;
  esac
done

if [[ -z "${HTML_PATH}" ]]; then
  usage
  die "No HTML file provided."
fi

if [[ -n "${MODULES}" && "${MODE_ALL}" -eq 1 ]]; then
  die "Use --modules or --all, not both."
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

build_module_regex() {
  local rel_pattern="$1"
  printf '%s' "(?:https:\\/\\/${BASE_HOST_ESCAPED}\\/)?${rel_pattern}|https:\\/\\/${BASE_HOST_ESCAPED}\\/${rel_pattern}|\\/${rel_pattern}"
}

SELECTED_MODULES=()
if [[ -n "${MODULES}" ]]; then
  IFS=',' read -r -a SELECTED_MODULES <<< "${MODULES}"
  echo "[i] Mode: --modules (${MODULES})"
elif [[ "${MODE_ALL}" -eq 1 ]]; then
  SELECTED_MODULES=("${MODULE_NAMES[@]}")
  echo "[i] Mode: --all (${#SELECTED_MODULES[@]} modules)"
else
  SELECTED_MODULES=("${DEFAULT_MODULES[@]}")
  echo "[i] Mode: default (${DEFAULT_MODULES[*]})"
fi

if [[ "${#SELECTED_MODULES[@]}" -eq 0 ]]; then
  die "No modules selected."
fi

GREP_RE=""
for module in "${SELECTED_MODULES[@]}"; do
  if [[ -z "${MODULE_PATTERNS[${module}]:-}" ]]; then
    die "Unknown module: ${module}"
  fi
  module_regex="$(build_module_regex "${MODULE_PATTERNS[${module}]}")"
  if [[ -z "${GREP_RE}" ]]; then
    GREP_RE="${module_regex}"
  else
    GREP_RE="${GREP_RE}|${module_regex}"
  fi
done

# Extraction pipeline:
# 1) grep matches (may be escaped)
# 2) unescape \/ -> /
# 3) strip leading origin if present (we’ll re-add BASE)
# 4) ensure leading slash
# 5) canonicalize to BASE + path
# 6) sort unique
grep -oP "${GREP_RE}" "${HTML_PATH}" \
  | sed 's#\\/#/#g' \
  | sed "s#^https\\?://${BASE_HOST_ESCAPED}##" \
  | sed 's#^mod/#/mod/#' \
  | sed "s#^#${BASE_URL}#; s#${BASE_URL}${BASE_URL}#${BASE_URL}#g" \
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
