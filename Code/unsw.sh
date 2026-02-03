#!/usr/bin/env bash
set -euo pipefail

# unsw.sh
# UNSW Moodle downloader wrapper (separate from solomon.sh)

# ---------------------------------------------------------------------
# Block 0: Resolve paths and define constants
# ---------------------------------------------------------------------
PROJECT_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"

COOKIES="${PROJECT_ROOT}/cookies.json"
SANITIZER="${PROJECT_ROOT}/sanitize-cookies.js"
EXTRACTOR="${PROJECT_ROOT}/extract-resources.sh"
DOWNLOADER="${PROJECT_ROOT}/download-pdfs.js"
RESOURCE_FILE="${PROJECT_ROOT}/resource_urls.txt"
BACKUP_DIR="${PROJECT_ROOT}/.backups"
OUTPUT_DIR_DEFAULT="UNSW"
OUTPUT_DIR="${OUTPUT_DIR:-${OUTPUT_DIR_DEFAULT}}"
BASE_URL_DEFAULT="https://moodle.telt.unsw.edu.au"
BASE_URL="${BASE_URL:-${BASE_URL_DEFAULT}}"

# ---------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------
die() { echo; echo "[✗] $1"; echo; exit 1; }
pause() { read -rp "Continue? [ENTER]"; }
banner() {
  echo
  echo "========================================="
  echo " $1"
  echo "========================================="
}

# ---------------------------------------------------------------------
# Block 1: Environment checks (non-invasive)
# ---------------------------------------------------------------------
banner "Environment Check"

command -v node >/dev/null || die "Node.js is not installed.\n\n→ Install Node.js (v20+) from https://nodejs.org/\n→ Then re-run unsw.sh"
command -v npm >/dev/null || die "npm is not installed.\n\n→ Install npm (bundled with Node.js)\n→ Then re-run unsw.sh"
command -v file >/dev/null || die "file(1) is not installed.\n\n→ Install 'file' for MIME detection (e.g., apt install file / brew install file)\n→ Then re-run unsw.sh"

NODE_MAJOR="$(node -p 'process.versions.node.split(".")[0]')"
if [[ "${NODE_MAJOR}" -lt 20 ]]; then
  die "Node.js v20+ is required (detected v${NODE_MAJOR}).\n\n→ Upgrade Node.js to v20 or newer\n→ Then re-run unsw.sh"
fi

NODE_MODULES_DIR="${PROJECT_ROOT}/node_modules"
if [[ ! -d "${NODE_MODULES_DIR}" ]]; then
  if [[ -f "${PROJECT_ROOT}/package.json" ]]; then
    die "node_modules not found in:\n${NODE_MODULES_DIR}\n\n→ Run:\n    cd ${PROJECT_ROOT}\n    npm install\n→ Then re-run unsw.sh"
  fi
  die "node_modules not found in:\n${NODE_MODULES_DIR}\n\n→ Run:\n    cd ${PROJECT_ROOT}\n    npm install puppeteer\n→ Then re-run unsw.sh"
fi

node -e "require('puppeteer')" >/dev/null 2>&1 || die "Puppeteer is not installed or cannot be loaded.\n\n→ Run:\n    cd ${PROJECT_ROOT}\n    npm install puppeteer\n→ Then re-run unsw.sh"

mkdir -p "${BACKUP_DIR}"
echo "[i] Backups will be stored in: ${BACKUP_DIR}"

# ---------------------------------------------------------------------
# Block 2: Manifest / Pre-flight display
# ---------------------------------------------------------------------
banner "UNSW Downloader – Manifest"

echo "[+] Project root: ${PROJECT_ROOT}"
echo
echo "[+] Node:"
node -v
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
if [[ "${OUTPUT_DIR}" != /* ]]; then
  OUTPUT_DIR="${PROJECT_ROOT}/${OUTPUT_DIR}"
fi

echo "Output directory:"
[[ -d "${OUTPUT_DIR}" ]] && echo "  - ${OUTPUT_DIR} (exists)" || echo "  - ${OUTPUT_DIR} (will be created)"
echo

pause

# ---------------------------------------------------------------------
# Block 3: Validate required files exist
# ---------------------------------------------------------------------
[[ -f "${COOKIES}" ]]    || die "cookies.json not found.\n\n→ Log into https://moodle.telt.unsw.edu.au\n→ Export cookies using Cookie-Editor (JSON format)\n→ Save as ${COOKIES}\n→ Then re-run unsw.sh"
[[ -f "${SANITIZER}" ]]  || die "sanitize-cookies.js missing.\n\n→ Restore sanitize-cookies.js in the project root\n→ Then re-run unsw.sh"
[[ -f "${EXTRACTOR}" ]]  || die "extract-resources.sh missing.\n\n→ Restore extract-resources.sh in the project root\n→ Then re-run unsw.sh"
[[ -f "${DOWNLOADER}" ]] || die "download-pdfs.js missing.\n\n→ Restore download-pdfs.js in the project root\n→ Then re-run unsw.sh"

mkdir -p "${OUTPUT_DIR}"

# ---------------------------------------------------------------------
# Block 4: Cookie sanitisation
# ---------------------------------------------------------------------
banner "Cookie Validation"

echo "[+] Using cookies.json"
echo "[+] Sanitising cookies..."
(
  cd "${PROJECT_ROOT}"
  node "${SANITIZER}"
)

# ---------------------------------------------------------------------
# Block 5: Choose course HTML file
# ---------------------------------------------------------------------
banner "Course HTML Selection"
shopt -s nullglob
HTML_FILES=("${PROJECT_ROOT}"/*.html)
shopt -u nullglob

if [[ "${#HTML_FILES[@]}" -eq 0 ]]; then
  die "No .html course pages found.\n\n→ Open your UNSW Moodle course page\n→ Use 'Save page as…' and choose 'Webpage, HTML only'\n→ Place the .html file in ${PROJECT_ROOT}\n→ Then re-run unsw.sh"
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
# Block 6: Mode prompt (resources-only vs all types)
# ---------------------------------------------------------------------
banner "Download Mode"

echo
read -rp "Download all activity types (resource + page + url)? [y/N] " dl_all
if [[ "${dl_all}" =~ ^[Yy]$ ]]; then
  MODE_ALL=1
  export DOWNLOAD_ALL=1
  echo "[i] Mode selected: ALL file types"
else
  MODE_ALL=0
  export DOWNLOAD_ALL=0
  echo "[i] Mode selected: resource only"
fi

# ---------------------------------------------------------------------
# Block 7: Output folder
# ---------------------------------------------------------------------
HTML_BASENAME="$(basename "${HTML}" .html)"
HTML_BASENAME="${HTML_BASENAME// /}"
HTML_BASENAME="${HTML_BASENAME//[^a-zA-Z0-9_]/_}"

UNSW_SUBDIR="${OUTPUT_DIR}/${HTML_BASENAME}"
mkdir -p "${UNSW_SUBDIR}"

echo "[+] Output subdirectory: ${UNSW_SUBDIR}"

# ---------------------------------------------------------------------
# Block 8: Extract Moodle URLs from HTML
# ---------------------------------------------------------------------
banner "Resource Extraction"
echo "[+] Extracting URLs..."

if [[ -f "${RESOURCE_FILE}" ]]; then
  TS=$(date +%Y%m%d-%H%M%S)
  mv "${RESOURCE_FILE}" "${BACKUP_DIR}/resource_urls.txt.${TS}.bak"
  echo "[i] Backed up existing resource_urls.txt -> ${BACKUP_DIR}/resource_urls.txt.${TS}.bak"
fi

if [[ "${MODE_ALL}" -eq 1 ]]; then
  BASE_URL="${BASE_URL}" "${EXTRACTOR}" --all "${HTML}"
else
  BASE_URL="${BASE_URL}" "${EXTRACTOR}" "${HTML}"
fi

[[ -f "${RESOURCE_FILE}" ]] || die "resource_urls.txt was not created.\n\n→ Ensure extract-resources.sh is present and executable\n→ Then re-run unsw.sh"
COUNT="$(grep -cve '^\s*$' "${RESOURCE_FILE}")"
[[ "${COUNT}" -gt 0 ]] || die "resource_urls.txt is empty.\n\n→ Confirm the course HTML contains Moodle links\n→ Then re-run unsw.sh"

echo "[+] ${COUNT} URL(s) extracted"

# ---------------------------------------------------------------------
# Block 9: Downloader runner
# ---------------------------------------------------------------------
run_downloader() {
  echo "[+] Starting download-pdfs.js..."
  env \
    OUTPUT_DIR="${UNSW_SUBDIR}" \
    DOWNLOAD_ALL="${DOWNLOAD_ALL:-0}" \
    DEBUG="${DEBUG:-0}" \
    node "${DOWNLOADER}"
}

# ---------------------------------------------------------------------
# Block 10: Safety test run (first 10 items)
# ---------------------------------------------------------------------
banner "Safety Test Run"

echo "[i] Safety test: downloading first 10 resources only"

echo "[+] Running test (first 10 items)... this may take a few minutes."

cp "${RESOURCE_FILE}" "${PROJECT_ROOT}/resource_urls.full.txt"
head -n 10 "${PROJECT_ROOT}/resource_urls.full.txt" > "${RESOURCE_FILE}"

(
  cd "${PROJECT_ROOT}"
  run_downloader
)

if [[ "${MODE_ALL}" -eq 1 ]]; then
  TEST_ANY="$(find "${UNSW_SUBDIR}" -type f | head -n 1 || true)"
  [[ -z "${TEST_ANY}" ]] && die "No file produced during test run (ALL mode).\n\n→ Check your cookies and access rights\n→ Then re-run unsw.sh"
  echo "[✓] Test validated (ALL mode): $(basename "${TEST_ANY}")"
else
  TEST_PDF="$(find "${UNSW_SUBDIR}" -type f -iname '*.pdf' | head -n 1 || true)"
  [[ -z "${TEST_PDF}" ]] && die "No PDF produced during test run (resource-only mode).\n\n→ Check your cookies and access rights\n→ Then re-run unsw.sh"
  FILE_TYPE="$(file -b "${TEST_PDF}" 2>/dev/null || echo '')"
  [[ "${FILE_TYPE}" != *PDF* ]] && die "Test output is not a valid PDF (${FILE_TYPE}).\n\n→ Verify the first resources are actual PDFs\n→ Then re-run unsw.sh"
  echo "[✓] Test validated (resource-only): $(basename "${TEST_PDF}")"
fi

echo "[✓] Test run passed — proceeding to full download"

# ---------------------------------------------------------------------
# Block 11: Bulk download
# ---------------------------------------------------------------------
banner "Full Download"

echo "[i] Bulk download started — this may take several minutes depending on course size."
echo "[+] Running bulk download..."

mv "${PROJECT_ROOT}/resource_urls.full.txt" "${RESOURCE_FILE}"

(
  cd "${PROJECT_ROOT}"
  run_downloader
)

echo
echo "[✓] Download complete"
echo "[✓] Output saved to: ${UNSW_SUBDIR}"

# ---------------------------------------------------------------------
# Block 12: Summary (downloaded file types)
# ---------------------------------------------------------------------
banner "Summary (downloaded file types)"

if command -v file >/dev/null; then
  echo
  echo "By MIME type:"
  find "${UNSW_SUBDIR}" -type f -print0 \
    | xargs -0 -I{} file -b --mime-type "{}" 2>/dev/null \
    | sort | uniq -c | sort -nr \
    | awk '{printf "  %5s  %s\n",$1,$2}'

  echo
  echo "By extension:"
  find "${UNSW_SUBDIR}" -type f \
    | sed -n 's/.*\.\([A-Za-z0-9]\{1,8\}\)$/\1/p' \
    | tr '[:upper:]' '[:lower:]' \
    | sort | uniq -c | sort -nr \
    | awk '{printf "  %5s  .%s\n",$1,$2}'
else
  echo "  (file(1) not available; skipping MIME summary)"
fi

echo

echo "[✓] Completed successfully"
echo "[✓] Output saved to: ${UNSW_SUBDIR}"
