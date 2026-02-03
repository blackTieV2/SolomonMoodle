
# SolomonMoodle

SolomonMoodle is a **local, offline mirroring toolchain** for archiving Moodle course content using Node.js, Puppeteer, and a small set of Bash helper scripts.

It automates downloading **all accessible learning materials** from a Moodle instance, including:

* PDFs
* Audio files
* ZIP packages
* **Interactive HTML packages** that open via popup windows (`mod/resource`)

The tool is designed for **authorized, personal, and educational use**, producing a structured, auditable archive suitable for offline study or long-term reference.

---

## ✨ Features

* Handles Moodle `mod/resource` **popup HTML packages**
* Fully mirrors interactive content:

  * audio
  * images
  * JavaScript
  * fonts
* ZIP-first preference with safe PDF/HTML fallback
* Cookie-based authentication (no passwords stored)
* Robust against Moodle redirects and `onclick="window.open(...)"`
* End-of-run summaries by MIME type and file extension
* Defensive limits to prevent partial or runaway downloads

---

## 📦 Requirements

* **Node.js 20.x (LTS)**
* **npm**
* Linux or macOS

  * Windows supported via **WSL**
* Chromium dependencies

  * Automatically handled by Puppeteer

> This project is tested on Node.js 20 LTS.
> Newer versions may work but are not guaranteed.

---

## 🚀 Quick Start

### 1. Clone and install dependencies

```bash
git clone https://github.com/<your-username>/solomon-moodle.git
cd solomon-moodle/Code
npm install
```

---

### 2. Export your Moodle session cookies

1. Log into Moodle in your browser
2. Use a browser extension such as **Cookie-Editor**
3. Export cookies in **JSON format**
4. Save the file as `cookies.json` in the project root
5. Sanitize the cookies for Puppeteer:

```bash
node sanitize-cookies.js
```

> ⚠️ `cookies.json` grants the same access as your browser session.
> Treat it as sensitive and **do not commit it to Git**.

---

### 3. Save the Moodle course page

* Open the Moodle course page in your browser
* Save the page as **HTML** (e.g. `course.html`)
* Place the file in the project root

---

### 4. Extract resource URLs

```bash
BASE_URL="https://solomon.ugle.org.uk" ./extract-resources.sh course.html
```

This creates a `resource_urls.txt` file containing all detected Moodle activity links.

---

### 5. Run the downloader

```bash
./solomon.sh
```

You will be prompted to choose:

* **PDF-only mode** or **ALL file types**
* Optional debug output

Downloaded content will appear in the `Solomon/` directory.

---

## 🧭 Multi-site support

This repo ships with a stable **Solomon** workflow and an UNSW-specific wrapper. Each wrapper keeps output isolated.

* **Solomon:** `./solomon.sh` → `Solomon/`
* **UNSW:** `./unsw.sh` → `UNSW/`

---

## 🇦🇺 UNSW Usage (moodle.telt.unsw.edu.au)

### 1. Install dependencies

```bash
cd /path/to/SolomonMoodle/Code
npm install
```

### 2. Export cookies (UNSW)

1. Log into `https://moodle.telt.unsw.edu.au`
2. Use **Cookie-Editor** (or similar) to export cookies as JSON
3. Save as `cookies.json` in `Code/`

### 3. Save the course page as HTML

* Open the course page (e.g. `https://moodle.telt.unsw.edu.au/course/view.php?id=90386`)
* Use **Save page as…** → **Webpage, HTML only**
* Put the `.html` file into `Code/`

### 4. Run the UNSW wrapper

```bash
./unsw.sh
```

The script will:

* Print a manifest and environment checks
* Sanitize cookies (with backups in `.backups/`)
* Extract URLs from your saved HTML
* Run a 10-item safety test
* Download into `UNSW/<CourseName>/`

---

## 📁 Output Structure

```text
Solomon/
└── <DerivedCourseName>/
    ├── <RID>-<filename>.pdf
    ├── <RID>-<filename>.zip
    ├── <RID>-<filename>.mp3
    ├── <RID>-<filename>.meta.json
    ├── <RID>-package/
    │   ├── index.html
    │   └── ... mirrored assets ...
    ├── <RID>-page.html
    └── <RID>-page-main.html
```

* `*-package/` directories represent fully mirrored interactive HTML resources
* `.meta.json` files provide lightweight audit metadata per download

---

## ⚙️ Configuration (Advanced)

You can control behavior using environment variables:

| Variable                | Description                                |
| ----------------------- | ------------------------------------------ |
| `OUTPUT_DIR`            | Output directory for the downloader        |
| `DOWNLOAD_ALL=1`        | Download all file types (not just PDFs)    |
| `DEBUG=1`               | Enable verbose debug output                |
| `MAX_RETRIES=3`         | Retry count for unstable requests          |
| `HARVEST_SECONDS=12`    | Runtime harvest duration for HTML packages |
| `MIRROR_MAX_FILES=2000` | Maximum mirrored assets per package        |
| `MIRROR_MAX_DEPTH=8`    | Maximum recursive crawl depth              |
| `ALLOW_LARGE=1`         | Remove the default per-file size cap       |

You can also override extraction base URLs:

| Variable   | Description                                |
| ---------- | ------------------------------------------ |
| `BASE_URL` | Moodle base URL for URL extraction scripts (required) |

Example:

```bash
DOWNLOAD_ALL=1 DEBUG=1 ./solomon.sh
```

---

## 🔐 Security & Legal Notes

* This project is for **educational and personal use only**
* You must have **authorized access** to the Moodle instance
* You are responsible for complying with the platform’s terms of service
* Archived content may include private or sensitive material

> This project is **not affiliated with or endorsed by Moodle**.

---

## 🧭 Known Limitations

* `mod/page` activities are saved as rendered HTML snapshots (not full interactive lessons)
* Manual cookie export is required
* No resume / checkpointing (yet)

---

## 🤝 Contributing

Contributions, bug reports, and feature requests are welcome.

Please keep changes:

* focused
* well-documented
* compatible with Node.js 20 LTS

---

## 📌 Versioning

Current release: **v1.0.0**

See `CHANGELOG.md` for details.

---
