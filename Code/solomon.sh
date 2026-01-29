#!/usr/bin/env bash
set -euo pipefail

# solomon.sh
# Main orchestrator for Solomon downloads (Moodle course content)
# Semi-automatic, safe, and resumable
#
# Supports:
# - PDF-only mode (default)
# - ALL file types (HTML/DOCX/ZIP/videos/packages) via interactive prompt
#
# Features:
# - Extraction of resource URLs from course HTML
# - Sanitisation of exported Cookie-Editor JSON
# - Automated downloader using Puppeteer (headless browser)
# - Optional: Debug output, retry control, dynamic resource harvesting
#
# Optional environment variables (or define here manually):
#   DEBUG=1
#   DOWNLOAD_ALL=1
#   MAX_RETRIES=5
#   HARVEST_SECONDS=15
#   MIRROR_MAX_FILES=3000
#   MIRROR_MAX_DEPTH=10
#   ALLOW_LARGE=1

# ---------------------------------------------------------------------
# Block 0: Resolve paths and define constants
# Why: Allows running from any working directory, ensures relative path safety.
# ---------------------------------------------------------------------
PROJECT_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"

COOKIES="${PROJECT_ROOT}/cookies.json"
SANITIZER="${PROJECT_ROOT}/sanitize-cookies.js"
EXTRACTOR="${PROJECT_ROOT}/extract-resources.sh"
DOWNLOADER="${PROJECT_ROOT}/download-pdfs.js"
OUT_DIR="${PROJECT_ROOT}/Solomon"
RESOURCE_FILE="${PROJECT_ROOT}/resource_urls.txt"

# ---------------------------------------------------------------------
# Block 0.1: Optional override variables (tweak here or export externally)
# ---------------------------------------------------------------------
DEBUG="${DEBUG:-0}"
DOWNLOAD_ALL="${DOWNLOAD_ALL:-0}"
MAX_RETRIES="${MAX_RETRIES:-3}"
HARVEST_SECONDS="${HARVEST_SECONDS:-12}"
MIRROR_MAX_FILES="${MIRROR_MAX_FILES:-2000}"
MIRROR_MAX_DEPTH="${MIRROR_MAX_DEPTH:-8}"
ALLOW_LARGE="${ALLOW_LARGE:-0}"

# ---------------------------------------------------------------------
# Block 0.2: Helper functions
# Why: Reusable UI elements and fail-fast behavior.
# ---------------------------------------------------------------------
die() { echo; echo "[✗] $1"; echo; exit 1; }
pause() { read -rp "Press ENTER to continue..."; }
banner() {
  echo
  echo "========================================="
  echo " $1"
  echo "========================================="
}

# ---------------------------------------------------------------------
# Block 1: Environment checks (fail fast)
# What: Verify required tools before any downloads
# Why: Prevent long waits before discovering missing prerequisites
# ---------------------------------------------------------------------
banner "Environment Check"

command -v node >/dev/null || die "Node.js is not installed.\n\n→ Install Node.js (v20+) from https://nodejs.org/\n→ Then re-run solomon.sh"
command -v npm >/dev/null || die "npm is not installed.\n\n→ Install npm (bundled with Node.js)\n→ Then re-run solomon.sh"
command -v file >/dev/null || die "file(1) is not installed.\n\n→ Install 'file' for MIME detection (e.g., apt install file / brew install file)\n→ Then re-run solomon.sh"

NODE_MAJOR="$(node -p 'process.versions.node.split(\".\")[0]')"
if [[ "${NODE_MAJOR}" -lt 20 ]]; then
  die "Node.js v20+ is required (detected v${NODE_MAJOR}).\n\n→ Upgrade Node.js to v20 or newer\n→ Then re-run solomon.sh"
fi

if [[ ! -d "${PROJECT_ROOT}/node_modules" ]]; then
  die "node_modules not found.\n\n→ Run: npm install\n→ Then re-run solomon.sh"
fi

# ---------------------------------------------------------------------
# Block 2: Manifest / Pre-flight display
# What: Show current project configuration + files detected
# Why: Transparency and safety before destructive operations
# ---------------------------------------------------------------------
banner "Solomon Downloader – Manifest"

echo "[+] Project root: ${PROJECT_ROOT}"
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

echo "Output directory:"
[[ -d "${OUT_DIR}" ]] && echo "  - Solomon/ (exists)" || echo "  - Solomon/ (will be created)"
echo

echo "Node:"
node -v
echo

pause

# ---------------------------------------------------------------------
# Block 3: Validate required files exist
# Why: Stop early if anything critical is missing.
# ---------------------------------------------------------------------
[[ -f "${COOKIES}" ]]    || die "cookies.json not found.\n\n→ Export cookies from your browser using Cookie-Editor\n→ Save as cookies.json in the project root\n→ Then re-run solomon.sh"
[[ -f "${SANITIZER}" ]]  || die "sanitize-cookies.js missing.\n\n→ Restore sanitize-cookies.js in the project root\n→ Then re-run solomon.sh"
[[ -f "${EXTRACTOR}" ]]  || die "extract-resources.sh missing.\n\n→ Restore extract-resources.sh in the project root\n→ Then re-run solomon.sh"
[[ -f "${DOWNLOADER}" ]] || die "download-pdfs.js missing.\n\n→ Restore download-pdfs.js in the project root\n→ Then re-run solomon.sh"

# Ensure output directory is present
mkdir -p "${OUT_DIR}"

# ---------------------------------------------------------------------
# Block 4: Cookie sanitisation
# What: Convert Cookie-Editor export into Puppeteer-compatible format
# Why: Prevents runtime crashes due to invalid fields like 'partitionKey'
# ---------------------------------------------------------------------
banner "Cookie Validation"

echo "[+] Using cookies.json"
echo "[+] Sanitising cookies..."
node "${SANITIZER}"

# ---------------------------------------------------------------------
# Block 5: Choose course HTML file (semi-automatic)
# What: Auto-select if one HTML file; prompt if multiple.
# Why: Convenience + safety.
# ---------------------------------------------------------------------
banner "Course HTML Selection"
shopt -s nullglob
HTML_FILES=("${PROJECT_ROOT}"/*.html)
shopt -u nullglob

if [[ "${#HTML_FILES[@]}" -eq 0 ]]; then
  die "No .html course pages found. Please save your course page as a .html file in the project folder."
elif [[ "${#HTML_FILES[@]}" -eq 1 ]]; then
  HTML="${HTML_FILES[0]}"
else
  echo
  echo "Multiple HTML files found. Choose one:"
  select f in "${HTML_FILES[@]}"; do
    if [[ -n "${f}" ]]; then
      HTML="${f}"
      break
    fi
  done
fi

[[ -f "${HTML}" ]] || die "Selected HTML file not found."
echo "[+] Using HTML: $(basename "${HTML}")"

# ---------------------------------------------------------------------
# Block 6: Mode prompt (PDF-only vs ALL file types)
# What: Ask user whether to extract just PDFs or all file types (packages, zips, etc.)
# Why: PDF-only is faster; ALL captures full interactivity.
# ---------------------------------------------------------------------
banner "Download Mode"
echo
read -rp "Download non-PDF resources too (HTML/DOCX/ZIP/videos/packages)? [y/N] " dl_all
if [[ "${dl_all}" =~ ^[Yy]$ ]]; then
  MODE_ALL=1
  export DOWNLOAD_ALL=1
  echo "[i] Mode selected: ALL file types"
else
  MODE_ALL=0
  export DOWNLOAD_ALL=0
  echo "[i] Mode selected: PDF only"
fi

# ---------------------------------------------------------------------
# Block 6a: Create working folder
# Derive subfolder name from HTML file (strip extension, sanitize)
# Why: Keeps extracted files grouped by course
# ---------------------------------------------------------------------
HTML_BASENAME="$(basename "${HTML}" .html)"
HTML_BASENAME="${HTML_BASENAME// /}"                        # Remove spaces
HTML_BASENAME="${HTML_BASENAME//[^a-zA-Z0-9_]/_}"           # Sanitize to safe chars

SOLOMON_SUBDIR="${OUT_DIR}/${HTML_BASENAME}"
export SOLOMON_SUBDIR
mkdir -p "${SOLOMON_SUBDIR}"

echo "[+] Output subdirectory: ${SOLOMON_SUBDIR}"

# ---------------------------------------------------------------------
# Block 6b: Prompt for Debug + Logging Options
# What: Ask whether to enable verbose debug output and what logging format to use
# Why: Keeps CLI clean for normal users but allows advanced diagnostics when needed
# ---------------------------------------------------------------------
banner "Logging Options"

# Prompt for debug mode
echo
read -rp "Enable debug output (verbose log messages)? [y/N] " dbg
if [[ "${dbg}" =~ ^[Yy]$ ]]; then
  export DEBUG=1
  echo "[i] Debug mode enabled"
else
  export DEBUG=0
  echo "[i] Debug mode disabled"
fi

# Prompt for logging preference
echo
echo "Choose logging output:"
echo "  [1] JSON log (machine-readable)"
echo "  [2] Legacy text manifest"
echo "  [3] Both"
echo "  [4] None"
read -rp "Select log output format [1-4, default=2]: " log_choice

case "${log_choice}" in
  1) export LOG_JSON=1; export LOG_MANIFEST=0; echo "[i] Using JSON logging only";;
  2|"") export LOG_JSON=0; export LOG_MANIFEST=1; echo "[i] Using legacy manifest only";;
  3) export LOG_JSON=1; export LOG_MANIFEST=1; echo "[i] Logging: JSON + Manifest";;
  4) export LOG_JSON=0; export LOG_MANIFEST=0; echo "[i] No log file will be written";;
  *) export LOG_JSON=0; export LOG_MANIFEST=1; echo "[i] Defaulting to legacy manifest";;
esac


# ---------------------------------------------------------------------
# Block 6: Extract Moodle URLs from HTML
# What: Run extractor script to generate resource_urls.txt
# Why: Converts course page into downloadable target list
# ---------------------------------------------------------------------
banner "Resource Extraction"
echo "[+] Extracting URLs..."

# Backup existing resource list (if any)
if [[ -f "${RESOURCE_FILE}" ]]; then
  TS=$(date +%Y%m%d-%H%M%S)
  mv "${RESOURCE_FILE}" "${RESOURCE_FILE}.${TS}.bak"
  echo "[i] Backed up existing resource_urls.txt -> resource_urls.txt.${TS}.bak"
fi

if [[ "${MODE_ALL}" -eq 1 ]]; then
  "${EXTRACTOR}" --all "${HTML}"
else
  "${EXTRACTOR}" "${HTML}"
fi

# Verify extractor output
[[ -f "${RESOURCE_FILE}" ]] || die "resource_urls.txt was not created.\n\n→ Ensure extract-resources.sh is present and executable\n→ Then re-run solomon.sh"
COUNT="$(grep -cve '^\s*$' "${RESOURCE_FILE}")"
[[ "${COUNT}" -gt 0 ]] || die "resource_urls.txt is empty.\n\n→ Confirm the course HTML contains resource links\n→ Then re-run solomon.sh"

echo "[+] ${COUNT} URL(s) extracted"


# ---------------------------------------------------------------------
# Block 7: Downloader runner (mode-aware, env-safe)
# What: Run Node downloader with or without DOWNLOAD_ALL flag
# Why: Keeps behavior aligned to selected mode, and forwards DEBUG too.
# ---------------------------------------------------------------------
run_downloader() {
  echo "[+] Starting download-pdfs.js..."
  if [[ "${DEBUG:-0}" == "1" ]]; then
    echo "[DEBUG] DOWNLOAD_ALL=${DOWNLOAD_ALL:-0}, DEBUG=${DEBUG:-0}"
  fi

  env DOWNLOAD_ALL="${DOWNLOAD_ALL:-0}" DEBUG="${DEBUG:-0}" node "${DOWNLOADER}"
}

# ---------------------------------------------------------------------
# Block 8: Safety test (first 10 items)
# What: Run test with only the first few URLs before bulk download
# Why: Prevent accidental mass downloads (e.g., login page as PDF)
# ---------------------------------------------------------------------
banner "Safety Test Run"
echo "[i] Safety test: downloading first 10 resources only (intentional and safe)"
echo "[+] Running test (first 10 items)... this may take a few minutes."

cp "${RESOURCE_FILE}" "${PROJECT_ROOT}/resource_urls.full.txt"
head -n 10 "${PROJECT_ROOT}/resource_urls.full.txt" > "${RESOURCE_FILE}"

run_downloader

# Validation: check for at least 1 file produced
if [[ "${MODE_ALL}" -eq 1 ]]; then
  TEST_ANY="$(find "${OUT_DIR}" -type f | head -n 1 || true)"
  [[ -z "${TEST_ANY}" ]] && die "No file produced during test run (ALL mode).\n\n→ Check your cookies and access rights\n→ Then re-run solomon.sh"
  echo "[✓] Test validated (ALL mode): $(basename "${TEST_ANY}")"
else
  TEST_PDF="$(find "${OUT_DIR}" -type f -iname '*.pdf' | head -n 1 || true)"
  [[ -z "${TEST_PDF}" ]] && die "No PDF produced during test run (PDF-only mode).\n\n→ Check your cookies and access rights\n→ Then re-run solomon.sh"
  FILE_TYPE="$(file -b "${TEST_PDF}" 2>/dev/null || echo '')"
  [[ "${FILE_TYPE}" != *PDF* ]] && die "Test output is not a valid PDF (${FILE_TYPE}).\n\n→ Verify the first resources are actual PDFs\n→ Then re-run solomon.sh"
  echo "[✓] Test validated (PDF-only): $(basename "${TEST_PDF}")"
fi

echo "[✓] Test run passed — proceeding to full download"

# ---------------------------------------------------------------------
# Block 9: Bulk download
# What: Restore full list and download all resources
# Why: Safe to proceed after test passes
# ---------------------------------------------------------------------
banner "Full Download"
echo "[i] Bulk download started — this may take several minutes depending on course size."
echo "[+] Running bulk download..."
mv "${PROJECT_ROOT}/resource_urls.full.txt" "${RESOURCE_FILE}"

run_downloader

echo
echo "[✓] Download complete"
echo "[✓] Output saved to: ${OUT_DIR}"
echo "[i] Next: review files in ${OUT_DIR}"
echo

# ---------------------------------------------------------------------
# Block 10: Summary (downloaded file types)
# What: Post-download audit of what was saved
# Why: Helps verify correct content types and detect edge cases
# ---------------------------------------------------------------------
banner "Summary (downloaded file types)"

if command -v file >/dev/null; then
  echo
  echo "By MIME type:"
  find "${OUT_DIR}" -type f -print0 \
    | xargs -0 -I{} file -b --mime-type "{}" 2>/dev/null \
    | sort | uniq -c | sort -nr \
    | awk '{printf "  %5s  %s\n",$1,$2}'

  echo
  echo "By extension:"
  find "${OUT_DIR}" -type f \
    | sed -n 's/.*\.\([A-Za-z0-9]\{1,8\}\)$/\1/p' \
    | tr '[:upper:]' '[:lower:]' \
    | sort | uniq -c | sort -nr \
    | awk '{printf "  %5s  .%s\n",$1,$2}'
else
  echo "  (file(1) not available; skipping MIME summary)"
fi

echo

# ---------------------------------------------------------------------
# Block 11: End-of-run summary + Optional JSON logging
# What: Emit structured logs if enabled.
# ---------------------------------------------------------------------
LOG_JSON_FILE=""
if [[ "${LOG_JSON:-0}" == "1" ]]; then
  TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  LOG_JSON_FILE="${PROJECT_ROOT}/solomon-log-${TS%%T*}.json"
  echo "[+] JSON logging enabled → ${LOG_JSON_FILE}"
  echo "[" > "${LOG_JSON_FILE}"
fi

# Emit file logs
if [[ -n "${LOG_JSON_FILE}" ]]; then
  find "${OUT_DIR}" -type f | while read -r f; do
    sz=$(stat -c%s "$f" 2>/dev/null || echo 0)
    mime=$(file -b --mime-type "$f" 2>/dev/null || echo "unknown")
    ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    bn=$(basename "$f")
    printf '  {\n    "timestamp": "%s",\n    "event": "file_saved",\n    "filename": "%s",\n    "mime": "%s",\n    "size_bytes": %s\n  },\n' "$ts" "$bn" "$mime" "$sz" >> "${LOG_JSON_FILE}"
  done

  # Trim last comma, close JSON array
  sed -i '$ s/},/}/' "${LOG_JSON_FILE}"
  echo "]" >> "${LOG_JSON_FILE}"
fi

echo
echo "[✓] Completed successfully"
echo "[✓] Output saved to: ${OUT_DIR}"
[[ -n "${LOG_JSON_FILE}" ]] && echo "[✓] Log saved to: ${LOG_JSON_FILE}"
echo

# ---------------------------------------------------------------------
# Block 12: Optional legacy manifest + archive
# ---------------------------------------------------------------------

TS=$(date +"%Y-%m-%d_%H-%M-%S")
SUMMARY_FILE="${SOLOMON_SUBDIR}/_download_manifest.${TS}.txt"

if [[ "${LOG_MANIFEST:-0}" == "1" ]]; then
  # Rebuild manifest (basic info + file list)
  {
    echo "Solomon Download Manifest"
    echo "========================="
    echo "Timestamp:       $(date '+%Y-%m-%d %H:%M:%S')"
    echo "HTML Source:     $(basename "${HTML}")"
    echo "Output Folder:   ${SOLOMON_SUBDIR}"
    echo "Mode:            $([[ "${MODE_ALL}" -eq 1 ]] && echo 'ALL resources' || echo 'PDF-only')"
    echo
    echo "Downloaded Files:"
    find "${SOLOMON_SUBDIR}" -type f | sed 's/^/  - /'
  } > "${SUMMARY_FILE}"

  echo "[✓] Manifest written to: ${SUMMARY_FILE}"
else
  echo "[i] Manifest logging disabled"
fi

# Optional: Archive output
if [[ "${MODE_ALL}" -eq 1 ]]; then
  ARCHIVE_PATH="${SOLOMON_SUBDIR}-${TS}.tar.gz"
  echo
  echo "[+] Creating archive: $(basename "${ARCHIVE_PATH}")"
  tar -czf "${ARCHIVE_PATH}" -C "${OUT_DIR}" "$(basename "${SOLOMON_SUBDIR}")"
  echo "[✓] Archive created: ${ARCHIVE_PATH}"
fi
