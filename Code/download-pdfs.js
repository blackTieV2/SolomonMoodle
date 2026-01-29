#!/usr/bin/env node
/**
 * download-pdfs.js — FINAL (robust)
 *
 * What it does:
 * - Reads Moodle activity URLs from: resource_urls.txt
 * - Uses session cookies from: cookies.json (Cookie-Editor export, then sanitized)
 * - Visits each activity page and extracts the real downloadable URL(s)
 * - Prefers ZIP packages when available (and verified)
 * - Downloads PDFs directly
 * - For interactive HTML "packages" (pluginfile .../mod_resource/content/<n>/index.html):
 *     - Saves index.html into Solomon/<RID>-package/
 *     - Static mirrors referenced assets (src/href/url())
 *     - Runtime harvests dynamically loaded assets by loading the page and capturing network
 * - Prints a summary at the end (counts by MIME + extension)
 *
 * Usage:
 *   node download-pdfs.js              # PDF-only
 *   DOWNLOAD_ALL=1 node download-pdfs.js  # download all file types + packages
 *
 * Optional env:
 *   MAX_RETRIES=3
 *   HARVEST_SECONDS=12
 *   MIRROR_MAX_FILES=2000
 *   MIRROR_MAX_DEPTH=8
 *   ALLOW_LARGE=1         # remove 200MB per-file cap
 */

/**
 * download-pdfs.js — FINAL (robust)
 * BLOCKS 1–3 (Config, Summary, Filename Hygiene)
 */

const puppeteer = require('puppeteer');
const fs = require('fs');
const path = require('path');

// ---------------------------------------------------------------------
// Block 1: Config
// ---------------------------------------------------------------------
const URL_FILE = 'resource_urls.txt';
const COOKIE_FILE = 'cookies.json';
const OUTPUT_DIR = process.env.SOLOMON_SUBDIR || 'Solomon';

const DOWNLOAD_ALL = process.env.DOWNLOAD_ALL === '1';
const MAX_RETRIES = Number(process.env.MAX_RETRIES || 3);
const DEBUG = process.argv.includes('--debug') || process.env.DEBUG === '1';

const MAX_BYTES_DEFAULT = 200 * 1024 * 1024;
const MAX_BYTES = process.env.ALLOW_LARGE === '1' ? Infinity : MAX_BYTES_DEFAULT;

const MIRROR_MAX_FILES = Number(process.env.MIRROR_MAX_FILES || 2000);
const MIRROR_MAX_DEPTH = Number(process.env.MIRROR_MAX_DEPTH || 8);
const HARVEST_SECONDS = Number(process.env.HARVEST_SECONDS || 12);

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

function logDebug(msg, ...args) {
  if (DEBUG) console.log(`[DEBUG] ${msg}`, ...args);
}

if (!fs.existsSync(OUTPUT_DIR)) fs.mkdirSync(OUTPUT_DIR, { recursive: true });

if (!fs.existsSync(URL_FILE)) {
  console.error(`❌ Missing ${URL_FILE} in current directory`);
  process.exit(1);
}

const urls = fs.readFileSync(URL_FILE, 'utf-8')
  .split('\n')
  .map((l) => l.trim())
  .filter(Boolean);

console.log(`[INFO] Saving files into: ${OUTPUT_DIR}`);
logDebug(`SOLOMON_SUBDIR: ${process.env.SOLOMON_SUBDIR}`);
logDebug(`OUTPUT_DIR: ${OUTPUT_DIR}`);
logDebug(`MAX_RETRIES: ${MAX_RETRIES}`);
logDebug(`DOWNLOAD_ALL: ${DOWNLOAD_ALL}`);
logDebug(`HARVEST_SECONDS: ${HARVEST_SECONDS}`);


// ---------------------------------------------------------------------
// Block 2: Run Summary Counters
// ---------------------------------------------------------------------
const summary = {
  processed: 0,
  savedFiles: 0,
  savedPackages: 0,
  skipped: 0,
  failed: 0,
  byMime: new Map(),
  byExt: new Map(),
};

function bump(map, key) {
  const k = key || 'unknown';
  map.set(k, (map.get(k) || 0) + 1);
}


// ---------------------------------------------------------------------
// Block 3: Filename hygiene + uniqueness
// ---------------------------------------------------------------------
function sanitizeFilename(name) {
  return String(name || '')
    .replace(/[%]/g, '_')
    .replace(/[^a-z0-9.\-_ ]/gi, '_')
    .replace(/\s+/g, ' ')
    .replace(/_+/g, '_')
    .trim()
    .substring(0, 240);
}

function uniquePath(dir, filename) {
  const base = path.join(dir, filename);
  if (!fs.existsSync(base)) return base;

  const ext = path.extname(filename);
  const stem = filename.slice(0, filename.length - ext.length);
  for (let i = 1; i < 10000; i++) {
    const candidate = path.join(dir, `${stem} (${i})${ext}`);
    if (!fs.existsSync(candidate)) return candidate;
  }
  return path.join(dir, `${stem}-${Date.now()}${ext}`);
}

function getResourceId(resourceUrl) {
  try {
    const u = new URL(resourceUrl);
    return (u.searchParams.get('id') || 'unknown').trim();
  } catch {
    return 'unknown';
  }
}

// ---------------------------------------------------------------------
// Block 4: Retry wrapper
// Why: Moodle pages sometimes glitch/timeout; this reduces operator babysitting.
// ---------------------------------------------------------------------
async function withRetries(fn, retries = MAX_RETRIES) {
  let lastErr;
  for (let i = 1; i <= retries; i++) {
    try {
      return await fn();
    } catch (e) {
      lastErr = e;
      console.warn(`⚠️ Retry ${i}/${retries} failed: ${e.message}`);
      await sleep(300 * i); // backoff
    }
  }
  throw lastErr;
}


// ---------------------------------------------------------------------
// Block 5: Magic-byte detection + extension mapping
// Why: avoid saving login HTML as "pdf", and verify ZIP-first logic.
// ---------------------------------------------------------------------
function looksLikePDF(buf) {
  return buf && buf.length >= 5 && buf.slice(0, 5).toString('ascii') === '%PDF-';
}

function looksLikeZIP(buf) {
  if (!buf || buf.length < 4) return false;
  return buf[0] === 0x50 && buf[1] === 0x4b &&
    (buf[2] === 0x03 || buf[2] === 0x05 || buf[2] === 0x07);
}

function looksLikeHTML(buf) {
  const s = buf.toString('utf8', 0, Math.min(buf.length, 512)).trim().toLowerCase();
  return (
    s.startsWith('<!doctype html') ||
    s.startsWith('<html') ||
    s.includes('<head') ||
    s.includes('<body')
  );
}

function extFromContentType(ct) {
  const c = (ct || '').toLowerCase();
  if (c.includes('pdf')) return '.pdf';
  if (c.includes('zip')) return '.zip';
  if (c.includes('msword')) return '.doc';
  if (c.includes('officedocument.wordprocessingml')) return '.docx';
  if (c.includes('officedocument.spreadsheetml')) return '.xlsx';
  if (c.includes('officedocument.presentationml')) return '.pptx';
  if (c.includes('text/html')) return '.html';
  if (c.includes('text/plain')) return '.txt';
  if (c.includes('text/css')) return '.css';
  if (c.includes('javascript')) return '.js';
  if (c.includes('image/png')) return '.png';
  if (c.includes('image/jpeg')) return '.jpg';
  if (c.includes('image/webp')) return '.webp';
  if (c.includes('image/svg')) return '.svg';
  if (c.includes('audio/mpeg') || c.includes('audio/mp3')) return '.mp3';
  if (c.includes('video/mp4')) return '.mp4';
  if (c.includes('font/woff2')) return '.woff2';
  if (c.includes('font/woff')) return '.woff';
  if (c.includes('font/ttf')) return '.ttf';
  return '';
}

// ---------------------------------------------------------------------
// Block 6: Candidate ranking
// Why: Moodle pages may offer multiple links; choose best one.
//       Prefer ZIP when real ZIP; otherwise PDF; otherwise index.html package.
// ---------------------------------------------------------------------
function scoreCandidate(urlStr) {
  const u = String(urlStr || '').toLowerCase();
  const isZip = u.includes('.zip');
  const isPdf = u.includes('.pdf');
  const isIndex = u.endsWith('/index.html') || u.includes('/index.html?');
  const isPluginfile = u.includes('/pluginfile.php/');
  const isForced = u.includes('forcedownload');

  if (isZip) return 1000 + (isPluginfile ? 10 : 0);
  if (isPdf) return 900 + (isPluginfile ? 10 : 0) + (isForced ? 5 : 0);
  if (isIndex) return 850 + (isPluginfile ? 10 : 0);
  if (isPluginfile) return 700 + (isForced ? 10 : 0);
  return 200;
}

function rankCandidates(candidates) {
  const deduped = Array.from(new Set((candidates || []).filter(Boolean)));
  const filtered = DOWNLOAD_ALL ? deduped : deduped.filter((h) => h.toLowerCase().includes('.pdf'));
  const scored = filtered.map((h) => ({ href: h, score: scoreCandidate(h) }));
  const sorted = scored.sort((a, b) => b.score - a.score);
  logDebug(`Ranked ${sorted.length} candidates`);
  return sorted;
}

// ---------------------------------------------------------------------
// Block 7: Browser-context fetch (preflight + full download)
// Why: uses session cookies + same-origin behavior automatically.
// ---------------------------------------------------------------------
async function preflight(page, fileUrl) {
  return await page.evaluate(async (url, timeoutMs) => {
    const doFetch = async (opts) => {
      const ctrl = new AbortController();
      const t = setTimeout(() => ctrl.abort(), timeoutMs);
      try {
        const resp = await fetch(url, {
          credentials: 'include',
          redirect: 'follow',
          signal: ctrl.signal,
          ...opts,
        });
        const ct = resp.headers.get('content-type') || '';
        const cl = resp.headers.get('content-length') || '';
        const status = resp.status;

        let prefix = null;
        if (opts.method !== 'HEAD') {
          const ab = await resp.arrayBuffer();
          prefix = Array.from(new Uint8Array(ab).slice(0, 256));
        }
        return { ok: resp.ok, status, ct, cl, prefix };
      } finally {
        clearTimeout(t);
      }
    };

    try {
      const head = await doFetch({ method: 'HEAD' });
      if (head.ok) return head;
    } catch (_) {}

    try {
      return await doFetch({ method: 'GET', headers: { Range: 'bytes=0-4095' } });
    } catch (e) {
      return { ok: false, status: 0, ct: '', cl: '', prefix: null, error: String(e) };
    }
  }, fileUrl, 15000);
}

async function downloadFull(page, fileUrl) {
  return await page.evaluate(async (url, timeoutMs) => {
    const ctrl = new AbortController();
    const t = setTimeout(() => ctrl.abort(), timeoutMs);
    try {
      const resp = await fetch(url, { credentials: 'include', redirect: 'follow', signal: ctrl.signal });
      const ct = resp.headers.get('content-type') || '';
      const cl = resp.headers.get('content-length') || '';
      const status = resp.status;
      if (!resp.ok) return { ok: false, status, ct, cl, data: null };
      const ab = await resp.arrayBuffer();
      return { ok: true, status: resp.status, ct, cl, data: Array.from(new Uint8Array(ab)) };
    } finally {
      clearTimeout(t);
    }
  }, fileUrl, 60000);
}

// ---------------------------------------------------------------------
// Block 8: HTML Package Detection + Mirroring
// Why: index.html is only an entry point; dynamic assets must be harvested.
// ---------------------------------------------------------------------
function isHtmlPackageIndex(urlStr) {
  try {
    const u = new URL(urlStr);
    return /\/pluginfile\.php\/\d+\/mod_resource\/content\/\d+\/index\.html$/i.test(u.pathname);
  } catch {
    return false;
  }
}

function baseDirOf(urlStr) {
  const u = new URL(urlStr);
  const idx = u.pathname.lastIndexOf('/');
  return `${u.origin}${u.pathname.slice(0, idx + 1)}`;
}

function normalizeRelPath(ref) {
  if (!ref) return null;
  const r = String(ref).trim();
  if (!r || r.startsWith('data:') || r.startsWith('blob:') || r.startsWith('javascript:')) return null;
  return r;
}

function shouldIgnoreRef(ref) {
  const r = ref.toLowerCase();
  return r.startsWith('#') || r.startsWith('mailto:') || r.startsWith('tel:');
}

function extractRefsFromText(text) {
  const out = new Set();
  for (const m of text.matchAll(/(?:src|href)\s*=\s*["']([^"']+)["']/gi)) out.add(m[1]);
  for (const m of text.matchAll(/url\(\s*['"]?([^'")]+)['"]?\s*\)/gi)) out.add(m[1]);
  for (const m of text.matchAll(/@import\s+(?:url\()?['"]([^'"]+)['"]\)?/gi)) out.add(m[1]);
  return Array.from(out);
}

function localPathForRef(pkgDir, ref) {
  const clean = ref.split('#')[0].split('?')[0].replace(/\\/g, '/');
  const safe = clean.replace(/^\/+/, '');
  if (!safe) return null;
  return path.join(pkgDir, safe);
}

async function fetchBinary(page, url) {
  return await page.evaluate(async (fileUrl, timeoutMs) => {
    const ctrl = new AbortController();
    const t = setTimeout(() => ctrl.abort(), timeoutMs);
    try {
      const resp = await fetch(fileUrl, { credentials: 'include', redirect: 'follow', signal: ctrl.signal });
      const ct = resp.headers.get('content-type') || '';
      const status = resp.status;
      if (!resp.ok) return { ok: false, status, ct, data: null };
      const ab = await resp.arrayBuffer();
      return { ok: true, status, ct, data: Array.from(new Uint8Array(ab)) };
    } catch (e) {
      return { ok: false, status: 0, ct: '', data: null, error: String(e) };
    } finally {
      clearTimeout(t);
    }
  }, url, 30000);
}

function ensureDir(dir) {
  if (!fs.existsSync(dir)) fs.mkdirSync(dir, { recursive: true });
}

function uniqueDir(dir) {
  if (!fs.existsSync(dir)) return dir;
  for (let i = 1; i < 10000; i++) {
    const candidate = `${dir}-${i}`;
    if (!fs.existsSync(candidate)) return candidate;
  }
  return `${dir}-${Date.now()}`;
}

async function mirrorHtmlPackage(browser, page, rid, entryUrl, entryBuf) {
  const baseDir = baseDirOf(entryUrl);
  const packageRoot = uniqueDir(path.join(OUTPUT_DIR, `${rid}-package`));
  ensureDir(packageRoot);

  const indexPath = path.join(packageRoot, 'index.html');
  fs.writeFileSync(indexPath, entryBuf);
  logDebug(`Saved HTML package entry: ${indexPath}`);

  const visitedUrls = new Set();
  const savedFiles = new Set();
  const queue = [];

  const seedRefs = extractRefsFromText(entryBuf.toString('utf8'));
  for (const ref of seedRefs) {
    const normalized = normalizeRelPath(ref);
    if (!normalized || shouldIgnoreRef(normalized)) continue;
    queue.push({ ref: normalized, depth: 1 });
  }

  while (queue.length && savedFiles.size < MIRROR_MAX_FILES) {
    const { ref, depth } = queue.shift();
    if (depth > MIRROR_MAX_DEPTH) continue;

    let absolute;
    try {
      absolute = new URL(ref, entryUrl).toString();
    } catch {
      continue;
    }

    if (!absolute.startsWith(baseDir)) {
      logDebug(`Skipping external ref: ${absolute}`);
      continue;
    }

    if (visitedUrls.has(absolute)) continue;
    visitedUrls.add(absolute);

    const localRef = absolute.slice(baseDir.length);
    const localPath = localPathForRef(packageRoot, localRef);
    if (!localPath) continue;
    ensureDir(path.dirname(localPath));

    const result = await withRetries(() => fetchBinary(page, absolute));
    if (!result || !result.ok || !result.data) continue;

    const dataBuf = Buffer.from(result.data);
    fs.writeFileSync(localPath, dataBuf);
    savedFiles.add(localPath);

    const contentType = (result.ct || '').toLowerCase();
    const isText = contentType.includes('text/') || contentType.includes('javascript') || contentType.includes('json');
    if (isText && depth < MIRROR_MAX_DEPTH) {
      const refs = extractRefsFromText(dataBuf.toString('utf8'));
      for (const child of refs) {
        const normalized = normalizeRelPath(child);
        if (!normalized || shouldIgnoreRef(normalized)) continue;
        queue.push({ ref: normalized, depth: depth + 1 });
      }
    }
  }

  const harvestPage = await browser.newPage();
  const harvestedUrls = new Set();
  harvestPage.on('response', async (resp) => {
    try {
      const url = resp.url();
      if (!url.startsWith(baseDir)) return;
      if (harvestedUrls.has(url)) return;
      harvestedUrls.add(url);

      const buffer = await resp.buffer();
      const rel = url.slice(baseDir.length);
      const localPath = localPathForRef(packageRoot, rel);
      if (!localPath) return;
      ensureDir(path.dirname(localPath));
      fs.writeFileSync(localPath, buffer);
    } catch (e) {
      logDebug(`Harvest response error: ${e.message}`);
    }
  });

  await withRetries(() => harvestPage.goto(entryUrl, { waitUntil: 'domcontentloaded' }));
  await sleep(HARVEST_SECONDS * 1000);
  await harvestPage.close();

  summary.savedPackages += 1;
  console.log(`📦 Mirrored HTML package: ${path.basename(packageRoot)}`);
}

// ---------------------------------------------------------------------
// Block 9: DOM extraction – extractCandidatesFromPage()
// ---------------------------------------------------------------------
async function extractCandidatesFromPage(page, resourceUrl) {
  logDebug(`🧪 Extracting candidates for: ${resourceUrl}`);

  // ✅ Correct delay (not page.waitForTimeout!)
  await new Promise(r => setTimeout(r, 2000));  // wait 2s for lazy load

  const divExists = await page.$('div.resourceworkaround') !== null;
  logDebug(`🔍 resourceworkaround div exists: ${divExists}`);

  const candidates = await page.evaluate(() => {
    const out = [];

    const push = (u) => { if (u) out.push(u); };

    const parseWindowOpen = (onclick) => {
      if (!onclick) return null;
      const s = String(onclick);

      let m = s.match(/window\.open\(\s*'([^']+)'/i);
      if (m && m[1]) return m[1];

      m = s.match(/window\.open\(\s*"([^"]+)"/i);
      if (m && m[1]) return m[1];

      return null;
    };

    document.querySelectorAll('div.resourceworkaround a').forEach((a) => {
      const href = a.getAttribute('href') || a.href;
      if (href) push(href);

      const onclick = a.getAttribute('onclick');
      const w = parseWindowOpen(onclick);
      if (w) push(w);
    });

    document.querySelectorAll('a[href*="pluginfile.php"]').forEach((a) => push(a.href));
    document.querySelectorAll('a[href*="forcedownload"]').forEach((a) => push(a.href));

    return Array.from(new Set(out));
  });

  logDebug(`✅ Found ${candidates.length} candidates:`);
  for (const c of candidates) logDebug(`    → ${c}`);

  return candidates;
}


// ---------------------------------------------------------------------
// Block 10: Main runner
// ---------------------------------------------------------------------
(async () => {
  if (!fs.existsSync(COOKIE_FILE)) {
    console.error(`❌ Missing ${COOKIE_FILE} in current directory`);
    process.exit(1);
  }

  const browser = await puppeteer.launch({
    headless: true,
    args: ['--no-sandbox', '--disable-setuid-sandbox'],
  });

  const page = await browser.newPage();

  // Load cookies
  const cookies = JSON.parse(fs.readFileSync(COOKIE_FILE, 'utf-8'));
  await page.setCookie(...cookies);

  for (const resourceUrl of urls) {
    summary.processed += 1;
    console.log(`\n🌐 Visiting ${resourceUrl}`);

    const rid = getResourceId(resourceUrl);

    try {
      await withRetries(() => page.goto(resourceUrl, { waitUntil: 'networkidle2' }));

      const candidates = await extractCandidatesFromPage(page, resourceUrl);
      if (!candidates.length) {
        console.warn('❌ No downloadable link candidates found');
        const html = await page.content();
        fs.writeFileSync(path.join(OUTPUT_DIR, `${rid}-page.html`), html);
        if (resourceUrl.includes('/mod/page/')) {
          const mainHtml = await page.$eval('div[role="main"], #region-main', (el) => el.outerHTML).catch(() => '');
          if (mainHtml) {
            fs.writeFileSync(path.join(OUTPUT_DIR, `${rid}-page-main.html`), mainHtml);
            logDebug(`Saved mod/page main HTML fallback for ${rid}`);
          }
        }
        summary.skipped += 1;
        continue;
      }

      const ranked = rankCandidates(candidates);
      if (!ranked.length) {
        console.warn(DOWNLOAD_ALL ? '❌ No suitable link candidates found' : '⏭️ Skipping (no PDF candidates found)');
        summary.skipped += 1;
        continue;
      }

      let chosen = null;

      for (const { href } of ranked) {
        const pf = await withRetries(() => preflight(page, href));
        if (!pf || !pf.ok) continue;

        const ctLower = (pf.ct || '').toLowerCase();
        const clNum = pf.cl ? Number(pf.cl) : NaN;
        if (!Number.isNaN(clNum) && clNum > MAX_BYTES) continue;

        if (!DOWNLOAD_ALL) {
          if (!ctLower.includes('pdf')) continue;
          chosen = href;
          break;
        }

        const looksZipByUrl = href.toLowerCase().includes('.zip');
        const prefixBuf = pf.prefix ? Buffer.from(pf.prefix) : null;
        const zipBySig = prefixBuf ? looksLikeZIP(prefixBuf) : false;
        const zipByCT = ctLower.includes('zip');

        if (looksZipByUrl && (zipByCT || zipBySig)) {
          chosen = href;
          break;
        }

        chosen = href;
        break;
      }

      if (!chosen) {
        console.warn('❌ No downloadable candidate passed preflight checks');
        summary.skipped += 1;
        continue;
      }

      logDebug(`Checking if chosen is HTML package: ${chosen}`);
      if (isHtmlPackageIndex(chosen)) {
        logDebug(`✅ Chosen URL looks like index.html HTML package`);
      } else {
        logDebug(`❌ Chosen URL is NOT an HTML package`);
      }

      const full = await withRetries(() => downloadFull(page, chosen));
      if (!full || !full.ok) {
        console.warn(`❌ Download failed: HTTP ${full?.status ?? '??'} (${full?.ct ?? 'no content-type'})`);
        summary.failed += 1;
        continue;
      }

      const buf = Buffer.from(full.data);
      const ctLower = (full.ct || '').toLowerCase();

      // PDF-only mode: enforce real PDF
      if (!DOWNLOAD_ALL && (!ctLower.includes('pdf') || !looksLikePDF(buf))) {
        console.warn(`⏭️ Skipping (not a real PDF; ct=${full.ct || 'n/a'})`);
        summary.skipped += 1;
        continue;
      }

      // HTML package
      if (DOWNLOAD_ALL && isHtmlPackageIndex(chosen) && looksLikeHTML(buf)) {
        await mirrorHtmlPackage(browser, page, rid, chosen, buf);
        continue;
      }

      // Regular file
      let rawName;
      try {
        const u = new URL(chosen);
        rawName = decodeURIComponent(path.basename(u.pathname || 'download'));
      } catch {
        rawName = 'download';
      }

      const hasExt = /\.[a-z0-9]{1,8}$/i.test(rawName);
      let ext = hasExt ? '' : extFromContentType(full.ct);
      if (!hasExt && !ext) ext = DOWNLOAD_ALL ? '.bin' : '.pdf';

      const finalName = hasExt ? sanitizeFilename(rawName) : sanitizeFilename(rawName + ext);
      const prefixed = sanitizeFilename(`${rid}-${finalName}`);
      const outPath = uniquePath(OUTPUT_DIR, prefixed);

      fs.writeFileSync(outPath, buf);

      // Save optional metadata file
      const meta = {
        id: rid,
        url: resourceUrl,
        downloadedFrom: chosen,
        contentType: full.ct || '',
        contentLength: full.cl || '',
      };
      fs.writeFileSync(outPath + '.meta.json', JSON.stringify(meta, null, 2));

      summary.savedFiles += 1;
      bump(summary.byMime, (full.ct || 'unknown').split(';')[0]);
      bump(summary.byExt, path.extname(outPath).toLowerCase() || '(no-ext)');

      console.log(`✅ Saved: ${path.basename(outPath)} (${full.ct || 'unknown type'})`);
    } catch (err) {
      summary.failed += 1;
      console.error(`❌ Failed for ${resourceUrl}: ${err.message}`);
    }
  }

  await browser.close();

  // ---------------------------------------------------------------------
  // Block 11: End-of-run summary
  // ---------------------------------------------------------------------
  console.log('\n=========================================');
  console.log(' Download Summary');
  console.log('=========================================');
  console.log(`Resources processed: ${summary.processed}`);
  console.log(`Saved files:        ${summary.savedFiles}`);
  console.log(`Saved packages:     ${summary.savedPackages}`);
  console.log(`Skipped:            ${summary.skipped}`);
  console.log(`Failed:             ${summary.failed}`);

  const byMimeSorted = [...summary.byMime.entries()].sort((a, b) => b[1] - a[1]);
  const byExtSorted = [...summary.byExt.entries()].sort((a, b) => b[1] - a[1]);

  if (byMimeSorted.length) {
    console.log('\nBy MIME type:');
    for (const [k, v] of byMimeSorted) console.log(`  ${v.toString().padStart(5)}  ${k}`);
  }

  if (byExtSorted.length) {
    console.log('\nBy extension:');
    for (const [k, v] of byExtSorted) console.log(`  ${v.toString().padStart(5)}  ${k}`);
  }

  console.log('\n🎉 All done.\n');
})();
