# SolomonMoodle

SolomonMoodle is a **local, offline mirroring toolchain** for archiving Moodle course content (PDFs, ZIPs, HTML packages, and more) using a Bash orchestrator plus a Puppeteer-based downloader. It is designed to take a saved Moodle course page and produce a structured archive with audit-friendly logs and metadata. The system prioritizes data completeness and provides safety controls (retry logic, file size caps, and run summaries) to avoid partial or corrupted downloads.

## What the code does

### 1) `solomon.sh` (orchestrator)
The Bash script is the main entry point. It:
- **Discovers input files** in the project directory (cookies, course HTML, scripts).
- **Sanitizes cookies** using `sanitize-cookies.js` to make them Puppeteer-compatible.
- **Extracts resource URLs** from the course HTML via `extract-resources.sh`.
- **Prompts for run mode** (PDF-only vs ALL file types), debug output, and logging format.
- **Sets runtime environment variables** (e.g., `DOWNLOAD_ALL`, `DEBUG`, `MAX_RETRIES`, `HARVEST_SECONDS`).
- **Creates a per-course output subfolder** inside `Solomon/` to keep downloads organized.
- **Invokes the downloader** (`download-pdfs.js`) with the chosen configuration.

This script provides the interactive UI and ensures the environment is ready before downloads begin.

### 2) `download-pdfs.js` (downloader)
The Node.js/Puppeteer downloader does the heavy lifting:
- **Reads URLs** from `resource_urls.txt`.
- **Launches Puppeteer** and loads sanitized cookies for authenticated access.
- **Visits each Moodle activity page** and extracts download candidates by inspecting the DOM.
- **Ranks candidates** to prioritize ZIP packages, then PDFs, then HTML package entry points.
- **Preflights downloads** to validate type and size before downloading full content.
- **Downloads files** with retry logic and writes them to the output folder using safe filenames.
- **Writes per-file metadata** (`.meta.json`) for audit trails.
- **Generates an end-of-run summary** with counts by MIME type and file extension.

#### HTML package mirroring
When downloading **interactive HTML packages** (e.g., `index.html` packages stored via Moodle `pluginfile.php`):
- The script saves the entry `index.html`.
- It **recursively crawls** referenced assets (`src`, `href`, `url()` in CSS) within the same base directory.
- It **runtime-harvests dynamic assets** by loading the entry page in Puppeteer and collecting network responses.
- All assets are saved into a dedicated `<RID>-package/` folder under the output directory.
- Limits such as `MIRROR_MAX_FILES` and `MIRROR_MAX_DEPTH` prevent runaway crawling.

#### `mod/page` fallback behavior
If a Moodle page yields **no direct download candidates**, the script saves:
- The full rendered HTML snapshot.
- A targeted `div[role="main"]` or `#region-main` fallback file for `mod/page` activities, which often embed content directly in the page.

### 3) `extract-resources.sh` (URL extractor)
This script parses the saved course HTML file and extracts Moodle activity URLs into `resource_urls.txt`. This ensures the downloader has a reliable, static list of resources to visit.

### 4) `sanitize-cookies.js` (cookie cleanup)
Converts a Cookie-Editor export into the format Puppeteer expects (removing fields like `partitionKey`). This avoids runtime crashes and authentication failures.

## Typical workflow
1. Save your Moodle course page as `course.html` in the project root.
2. Export your authenticated Moodle cookies from the browser (Cookie-Editor) as `cookies.json`.
3. Run:
   ```bash
   ./solomon.sh
   ```
4. Follow the prompts for mode, debug, and logging preferences.
5. Find outputs in `Solomon/<CourseName>/`.

## Output structure
```
Solomon/
└── <DerivedCourseName>/
    ├── <RID>-<filename>.pdf / .zip / .docx / etc.
    ├── <RID>-<filename>.meta.json
    ├── <RID>-package/
    │   ├── index.html
    │   └── ...assets...
    ├── <RID>-page.html
    └── <RID>-page-main.html
```

## Configuration (environment variables)
You can set these before running `solomon.sh` or export them in your shell:
- `DOWNLOAD_ALL=1` — download all file types (not just PDFs).
- `DEBUG=1` — enable verbose debug output.
- `MAX_RETRIES=3` — retries for unstable requests.
- `HARVEST_SECONDS=12` — runtime harvest duration for HTML packages.
- `MIRROR_MAX_FILES=2000` — cap on mirrored asset count.
- `MIRROR_MAX_DEPTH=8` — depth for recursive asset crawling.
- `ALLOW_LARGE=1` — remove the 200MB per-file size cap.

## Security notes
- Your cookies grant authenticated access; treat `cookies.json` as sensitive.
- Archived course content may include private or personal data.
- Consider keeping `Solomon/` and cookie files out of version control.
