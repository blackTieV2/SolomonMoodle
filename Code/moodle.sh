#!/usr/bin/env bash
set -euo pipefail

# moodle.sh
# Generic Moodle downloader wrapper that loads site profiles and plugins.

# ---------------------------------------------------------------------
# Block 0: Resolve paths and define constants
# ---------------------------------------------------------------------
PROJECT_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
REPO_ROOT="$(cd -- "${PROJECT_ROOT}/.." &>/dev/null && pwd)"
SITES_DIR="${REPO_ROOT}/sites"
PLUGINS_DIR="${PROJECT_ROOT}/plugins/modules"

COOKIES="${PROJECT_ROOT}/cookies.json"
SANITIZER="${PROJECT_ROOT}/sanitize-cookies.js"
EXTRACTOR="${PROJECT_ROOT}/extract-resources.sh"
DOWNLOADER="${PROJECT_ROOT}/download-pdfs.js"
RESOURCE_FILE="${PROJECT_ROOT}/resource_urls.txt"
BACKUP_DIR="${PROJECT_ROOT}/.backups"

DEBUG="${DEBUG:-0}"
DOWNLOAD_ALL="${DOWNLOAD_ALL:-0}"
MAX_RETRIES="${MAX_RETRIES:-3}"
HARVEST_SECONDS="${HARVEST_SECONDS:-12}"
MIRROR_MAX_FILES="${MIRROR_MAX_FILES:-2000}"
MIRROR_MAX_DEPTH="${MIRROR_MAX_DEPTH:-8}"
ALLOW_LARGE="${ALLOW_LARGE:-0}"

SITE="${MOODLE_SITE:-}"
HTML_PATH=""
MODE_ALL=0
MODULES=""
OUTPUT_DIR="${OUTPUT_DIR:-}"
LOG_CHOICE=""
CI_MODE="${CI_MODE:-0}"

# ---------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------
die() { echo; echo "[✗] $1"; echo; exit 1; }

pause() {
  if [[ "${CI_MODE}" -eq 1 ]]; then
    return
  fi
  read -rp "Press ENTER to continue..."
}

banner() {
  echo
  echo "========================================="
  echo " $1"
  echo "========================================="
}

usage() {
  cat <<EOF
Usage:
  $(basename "$0") --site <name> [options]

Options:
  --site <name>        Site profile name from ${SITES_DIR}
  --html <path>        HTML course page to use
  --all                Extract all known module types
  --modules <list>     Comma-separated module names (overrides --all)
  --output-dir <path>  Override output directory (base directory)
  --debug              Enable debug output
  --log <format>       Log format: json | manifest | both | none
  --ci                 Non-interactive mode (no prompts)
  -h, --help           Show this help

Examples:
  ./moodle.sh --site solomon
  ./moodle.sh --site unsw --all
  ./moodle.sh --site unsw --modules resource,page
  CI=1 ./moodle.sh --site solomon --html course.html --all
EOF
}

list_sites() {
  if [[ -d "${SITES_DIR}" ]]; then
    ls -1 "${SITES_DIR}"/*.env 2>/dev/null | sed 's#.*/##' | sed 's/\.env$//' || true
  fi
}

apply_log_choice() {
  case "${LOG_CHOICE}" in
    json) LOG_JSON=1; LOG_MANIFEST=0; echo "[i] Using JSON logging only";;
    manifest) LOG_JSON=0; LOG_MANIFEST=1; echo "[i] Using legacy manifest only";;
    both) LOG_JSON=1; LOG_MANIFEST=1; echo "[i] Logging: JSON + Manifest";;
    none) LOG_JSON=0; LOG_MANIFEST=0; echo "[i] No log file will be written";;
    "") return;;
    *) die "Invalid log format: ${LOG_CHOICE}";;
  esac
}

# ---------------------------------------------------------------------
# Block 1: Parse arguments
# ---------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --site)
      SITE="${2:-}"
      shift 2
      ;;
    --html)
      HTML_PATH="${2:-}"
      shift 2
      ;;
    --all)
      MODE_ALL=1
      shift
      ;;
    --modules)
      MODULES="${2:-}"
      shift 2
      ;;
    --output-dir)
      OUTPUT_DIR="${2:-}"
      shift 2
      ;;
    --debug)
      DEBUG=1
      shift
      ;;
    --log)
      LOG_CHOICE="${2:-}"
      shift 2
      ;;
    --ci)
      CI_MODE=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "Unknown argument: $1"
      ;;
  esac
done

if [[ -n "${CI:-}" ]]; then
  CI_MODE=1
fi

if [[ -n "${MODULES}" && "${MODE_ALL}" -eq 1 ]]; then
  die "Use --modules or --all, not both."
fi

# ---------------------------------------------------------------------
# Block 2: Resolve site profile
# ---------------------------------------------------------------------
if [[ -z "${SITE}" ]]; then
  AVAILABLE_SITES=( $(list_sites) )
  if [[ "${#AVAILABLE_SITES[@]}" -eq 1 ]]; then
    SITE="${AVAILABLE_SITES[0]}"
  elif [[ "${CI_MODE}" -eq 1 ]]; then
    die "No site specified. Use --site <name>."
  else
    echo "Available sites:"
    select s in "${AVAILABLE_SITES[@]}"; do
      if [[ -n "${s}" ]]; then
        SITE="${s}"
        break
      fi
    done
  fi
fi

SITE_FILE="${SITES_DIR}/${SITE}.env"
[[ -f "${SITE_FILE}" ]] || die "Site profile not found: ${SITE_FILE}"

set -a
# shellcheck source=/dev/null
source "${SITE_FILE}"
set +a

SITE_NAME="${SITE_NAME:-${SITE}}"
BASE_URL="${BASE_URL:-}"
OUTPUT_DIR_DEFAULT="${OUTPUT_DIR_DEFAULT:-${SITE_NAME}}"

[[ -n "${BASE_URL}" ]] || die "BASE_URL is not set in ${SITE_FILE}"

# ---------------------------------------------------------------------
# Block 3: Environment checks (fail fast)
# ---------------------------------------------------------------------
banner "${SITE_NAME} Downloader – Environment Check"

command -v node >/dev/null || die "Node.js is not installed.\n\n→ Install Node.js (v20+) from https://nodejs.org/\n→ Then re-run moodle.sh"
command -v npm >/dev/null || die "npm is not installed.\n\n→ Install npm (bundled with Node.js)\n→ Then re-run moodle.sh"
command -v file >/dev/null || die "file(1) is not installed.\n\n→ Install 'file' for MIME detection (e.g., apt install file / brew install file)\n→ Then re-run moodle.sh"

NODE_MAJOR="$(node -p 'process.versions.node.split(".")[0]')"
if [[ "${NODE_MAJOR}" -lt 20 ]]; then
  die "Node.js v20+ is required (detected v${NODE_MAJOR}).\n\n→ Upgrade Node.js to v20 or newer\n→ Then re-run moodle.sh"
fi

NODE_MODULES_DIR="${PROJECT_ROOT}/node_modules"
if [[ ! -d "${NODE_MODULES_DIR}" ]]; then
  if [[ -f "${PROJECT_ROOT}/package.json" ]]; then
    die "node_modules not found in:\n${NODE_MODULES_DIR}\n\n→ Run:\n    cd ${PROJECT_ROOT}\n    npm install\n→ Then re-run moodle.sh"
  fi
  die "node_modules not found in:\n${NODE_MODULES_DIR}\n\n→ Run:\n    cd ${PROJECT_ROOT}\n    npm install puppeteer\n→ Then re-run moodle.sh"
fi

node -e "require('puppeteer')" >/dev/null 2>&1 || die "Puppeteer is not installed or cannot be loaded.\n\n→ Run:\n    cd ${PROJECT_ROOT}\n    npm install puppeteer\n→ Then re-run moodle.sh"

mkdir -p "${BACKUP_DIR}"
echo "[i] Backups will be stored in: ${BACKUP_DIR}"

# ---------------------------------------------------------------------
# Block 4: Manifest / Pre-flight display
# ---------------------------------------------------------------------
banner "${SITE_NAME} Downloader – Manifest"

echo "[+] Project root: ${PROJECT_ROOT}"
echo "[+] Site profile: ${SITE_FILE}"
echo

echo "[+] Detected files:"
echo

echo "Cookies:"
ls -1 "${PROJECT_ROOT}"/cookies*.json 2>/dev/null || echo "  (none)"
echo

echo "HTML course pages:"
ls -1 "${PROJECT_ROOT}"/*.html 2>/dev/null || echo "  (none)"
echo

echo "Scripts:"
for f in sanitize-cookies.js extract-resources.sh download-pdfs.js; do
  [[ -f "${PROJECT_ROOT}/${f}" ]] && echo "  - ${f}" || echo "  - ${f} (MISSING)"
done

echo
if [[ -z "${OUTPUT_DIR}" ]]; then
  OUTPUT_DIR="${OUTPUT_DIR_DEFAULT}"
fi

if [[ "${OUTPUT_DIR}" != /* ]]; then
  OUTPUT_DIR="${PROJECT_ROOT}/${OUTPUT_DIR}"
fi

OUTPUT_ROOT="${OUTPUT_DIR}"

echo "Output directory:"
[[ -d "${OUTPUT_DIR}" ]] && echo "  - ${OUTPUT_DIR} (exists)" || echo "  - ${OUTPUT_DIR} (will be created)"
echo

echo "Node:"
node -v
echo

pause

# ---------------------------------------------------------------------
# Block 5: Validate required files exist
# ---------------------------------------------------------------------
[[ -f "${COOKIES}" ]]    || die "cookies.json not found.\n\n→ Export cookies from your browser using Cookie-Editor\n→ Save as cookies.json in the project root\n→ Then re-run moodle.sh"
[[ -f "${SANITIZER}" ]]  || die "sanitize-cookies.js missing.\n\n→ Restore sanitize-cookies.js in the project root\n→ Then re-run moodle.sh"
[[ -f "${EXTRACTOR}" ]]  || die "extract-resources.sh missing.\n\n→ Restore extract-resources.sh in the project root\n→ Then re-run moodle.sh"
[[ -f "${DOWNLOADER}" ]] || die "download-pdfs.js missing.\n\n→ Restore download-pdfs.js in the project root\n→ Then re-run moodle.sh"

mkdir -p "${OUTPUT_DIR}"

# ---------------------------------------------------------------------
# Block 6: Cookie sanitisation
# ---------------------------------------------------------------------
banner "Cookie Validation"

echo "[+] Using cookies.json"
echo "[+] Sanitising cookies..."
node "${SANITIZER}"

# ---------------------------------------------------------------------
# Block 7: Choose course HTML file
# ---------------------------------------------------------------------
banner "Course HTML Selection"

shopt -s nullglob
HTML_FILES=("${PROJECT_ROOT}"/*.html)
shopt -u nullglob

if [[ -n "${HTML_PATH}" ]]; then
  [[ -f "${HTML_PATH}" ]] || die "HTML file not found: ${HTML_PATH}"
  HTML="${HTML_PATH}"
else
  if [[ "${#HTML_FILES[@]}" -eq 0 ]]; then
    die "No .html course pages found. Please save your course page as a .html file in the project folder."
  elif [[ "${#HTML_FILES[@]}" -eq 1 ]]; then
    HTML="${HTML_FILES[0]}"
  else
    if [[ "${CI_MODE}" -eq 1 ]]; then
      die "Multiple HTML files found. Use --html to select one."
    fi
    echo
    echo "Multiple HTML files found. Choose one:"
    select f in "${HTML_FILES[@]}"; do
      if [[ -n "${f}" ]]; then
        HTML="${f}"
        break
      fi
    done
  fi
fi

[[ -f "${HTML}" ]] || die "Selected HTML file not found."
echo "[+] Using HTML: $(basename "${HTML}")"

# ---------------------------------------------------------------------
# Block 8: Download mode
# ---------------------------------------------------------------------
if [[ "${MODE_ALL}" -eq 1 ]]; then
  MODE_ALL=1
elif [[ -n "${MODULES}" ]]; then
  MODE_ALL=0
elif [[ "${CI_MODE}" -eq 1 ]]; then
  MODE_ALL=0
else
  banner "Download Mode"
  echo
  read -rp "Download non-PDF resources too (HTML/DOCX/ZIP/videos/packages)? [y/N] " dl_all
  if [[ "${dl_all}" =~ ^[Yy]$ ]]; then
    MODE_ALL=1
  else
    MODE_ALL=0
  fi
fi

if [[ "${MODE_ALL}" -eq 1 ]]; then
  export DOWNLOAD_ALL=1
  echo "[i] Mode selected: ALL file types"
elif [[ -n "${MODULES}" ]]; then
  export DOWNLOAD_ALL=1
  echo "[i] Mode selected: modules (${MODULES})"
else
  export DOWNLOAD_ALL=0
  echo "[i] Mode selected: resource only"
fi

# ---------------------------------------------------------------------
# Block 9: Output folder
# ---------------------------------------------------------------------
HTML_BASENAME="$(basename "${HTML}" .html)"
HTML_BASENAME="${HTML_BASENAME// /}"
HTML_BASENAME="${HTML_BASENAME//[^a-zA-Z0-9_]/_}"

OUTPUT_SUBDIR="${OUTPUT_ROOT}/${HTML_BASENAME}"
export OUTPUT_DIR="${OUTPUT_SUBDIR}"
mkdir -p "${OUTPUT_SUBDIR}"

echo "[+] Output subdirectory: ${OUTPUT_SUBDIR}"

# ---------------------------------------------------------------------
# Block 10: Logging options
# ---------------------------------------------------------------------
if [[ -n "${LOG_CHOICE}" ]]; then
  apply_log_choice
elif [[ "${CI_MODE}" -eq 1 ]]; then
  LOG_JSON="${LOG_JSON:-0}"
  LOG_MANIFEST="${LOG_MANIFEST:-1}"
else
  banner "Logging Options"

  echo
  read -rp "Enable debug output (verbose log messages)? [y/N] " dbg
  if [[ "${dbg}" =~ ^[Yy]$ ]]; then
    export DEBUG=1
    echo "[i] Debug mode enabled"
  else
    export DEBUG=0
    echo "[i] Debug mode disabled"
  fi

  echo
  echo "Choose logging output:"
  echo "  [1] JSON log (machine-readable)"
  echo "  [2] Legacy text manifest"
  echo "  [3] Both"
  echo "  [4] None"
  read -rp "Select log output format [1-4, default=2]: " log_choice

  case "${log_choice}" in
    1) LOG_CHOICE="json";;
    2|"") LOG_CHOICE="manifest";;
    3) LOG_CHOICE="both";;
    4) LOG_CHOICE="none";;
    *) LOG_CHOICE="manifest";;
  esac
  apply_log_choice
fi

# ---------------------------------------------------------------------
# Block 11: Extract Moodle URLs from HTML
# ---------------------------------------------------------------------
banner "Resource Extraction"
echo "[+] Extracting URLs..."

if [[ -f "${RESOURCE_FILE}" ]]; then
  TS=$(date +%Y%m%d-%H%M%S)
  mv "${RESOURCE_FILE}" "${BACKUP_DIR}/resource_urls.txt.${TS}.bak"
  echo "[i] Backed up existing resource_urls.txt -> ${BACKUP_DIR}/resource_urls.txt.${TS}.bak"
fi

EXTRACTOR_ARGS=()
if [[ -n "${MODULES}" ]]; then
  EXTRACTOR_ARGS+=(--modules "${MODULES}")
elif [[ "${MODE_ALL}" -eq 1 ]]; then
  EXTRACTOR_ARGS+=(--all)
fi

BASE_URL="${BASE_URL}" "${EXTRACTOR}" "${EXTRACTOR_ARGS[@]}" "${HTML}"

[[ -f "${RESOURCE_FILE}" ]] || die "resource_urls.txt was not created.\n\n→ Ensure extract-resources.sh is present and executable\n→ Then re-run moodle.sh"
COUNT="$(grep -cve '^\s*$' "${RESOURCE_FILE}")"
[[ "${COUNT}" -gt 0 ]] || die "resource_urls.txt is empty.\n\n→ Confirm the course HTML contains resource links\n→ Then re-run moodle.sh"

echo "[+] ${COUNT} URL(s) extracted"

# ---------------------------------------------------------------------
# Block 12: Downloader runner
# ---------------------------------------------------------------------
run_downloader() {
  echo "[+] Starting download-pdfs.js..."
  if [[ "${DEBUG:-0}" == "1" ]]; then
    echo "[DEBUG] DOWNLOAD_ALL=${DOWNLOAD_ALL:-0}, DEBUG=${DEBUG:-0}"
  fi

  env OUTPUT_DIR="${OUTPUT_DIR}" DOWNLOAD_ALL="${DOWNLOAD_ALL:-0}" DEBUG="${DEBUG:-0}" node "${DOWNLOADER}"
}

# ---------------------------------------------------------------------
# Block 13: Safety test run (first 10 items)
# ---------------------------------------------------------------------
banner "Safety Test Run"

echo "[i] Safety test: downloading first 10 resources only (intentional and safe)"

echo "[+] Running test (first 10 items)... this may take a few minutes."

cp "${RESOURCE_FILE}" "${PROJECT_ROOT}/resource_urls.full.txt"
head -n 10 "${PROJECT_ROOT}/resource_urls.full.txt" > "${RESOURCE_FILE}"

run_downloader

if [[ "${MODE_ALL}" -eq 1 || -n "${MODULES}" ]]; then
  TEST_ANY="$(find "${OUTPUT_SUBDIR}" -type f | head -n 1 || true)"
  [[ -z "${TEST_ANY}" ]] && die "No file produced during test run (ALL mode).\n\n→ Check your cookies and access rights\n→ Then re-run moodle.sh"
  echo "[✓] Test validated: $(basename "${TEST_ANY}")"
else
  TEST_PDF="$(find "${OUTPUT_SUBDIR}" -type f -iname '*.pdf' | head -n 1 || true)"
  [[ -z "${TEST_PDF}" ]] && die "No PDF produced during test run (resource-only mode).\n\n→ Check your cookies and access rights\n→ Then re-run moodle.sh"
  FILE_TYPE="$(file -b "${TEST_PDF}" 2>/dev/null || echo '')"
  [[ "${FILE_TYPE}" != *PDF* ]] && die "Test output is not a valid PDF (${FILE_TYPE}).\n\n→ Verify the first resources are actual PDFs\n→ Then re-run moodle.sh"
  echo "[✓] Test validated (resource-only): $(basename "${TEST_PDF}")"
fi

echo "[✓] Test run passed — proceeding to full download"

# ---------------------------------------------------------------------
# Block 14: Bulk download
# ---------------------------------------------------------------------
banner "Full Download"

echo "[i] Bulk download started — this may take several minutes depending on course size."
echo "[+] Running bulk download..."

mv "${PROJECT_ROOT}/resource_urls.full.txt" "${RESOURCE_FILE}"

run_downloader

echo
echo "[✓] Download complete"
echo "[✓] Output saved to: ${OUTPUT_SUBDIR}"

echo

# ---------------------------------------------------------------------
# Block 15: Summary (downloaded file types)
# ---------------------------------------------------------------------
banner "Summary (downloaded file types)"

if command -v file >/dev/null; then
  echo
  echo "By MIME type:"
  find "${OUTPUT_SUBDIR}" -type f -print0 \
    | xargs -0 -I{} file -b --mime-type "{}" 2>/dev/null \
    | sort | uniq -c | sort -nr \
    | awk '{printf "  %5s  %s\n",$1,$2}'

  echo
  echo "By extension:"
  find "${OUTPUT_SUBDIR}" -type f \
    | sed -n 's/.*\.\([A-Za-z0-9]\{1,8\}\)$/\1/p' \
    | tr '[:upper:]' '[:lower:]' \
    | sort | uniq -c | sort -nr \
    | awk '{printf "  %5s  .%s\n",$1,$2}'
else
  echo "  (file(1) not available; skipping MIME summary)"
fi

echo

# ---------------------------------------------------------------------
# Block 16: End-of-run summary + Optional JSON logging
# ---------------------------------------------------------------------
LOG_JSON_FILE=""
if [[ "${LOG_JSON:-0}" == "1" ]]; then
  TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  LOG_JSON_FILE="${PROJECT_ROOT}/solomon-log-${TS%%T*}.json"
  echo "[+] JSON logging enabled → ${LOG_JSON_FILE}"
  echo "[" > "${LOG_JSON_FILE}"
fi

if [[ -n "${LOG_JSON_FILE}" ]]; then
  find "${OUTPUT_SUBDIR}" -type f | while read -r f; do
    sz=$(stat -c%s "$f" 2>/dev/null || echo 0)
    mime=$(file -b --mime-type "$f" 2>/dev/null || echo "unknown")
    ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    bn=$(basename "$f")
    printf '  {\n    "timestamp": "%s",\n    "event": "file_saved",\n    "filename": "%s",\n    "mime": "%s",\n    "size_bytes": %s\n  },\n' "$ts" "$bn" "$mime" "$sz" >> "${LOG_JSON_FILE}"
  done

  sed -i '$ s/},/}/' "${LOG_JSON_FILE}"
  echo "]" >> "${LOG_JSON_FILE}"
fi
