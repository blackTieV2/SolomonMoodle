#!/usr/bin/env node

/**
 * sanitize-cookies.js
 *
 * Converts browser-exported cookies.json into a
 * Puppeteer-safe minimal format.
 *
 * Self-resolving: operates relative to its own location.
 */

const fs = require('fs');
const path = require('path');

// Resolve project root (directory where this script lives)
const PROJECT_ROOT = path.dirname(path.resolve(__filename));
const COOKIE_PATH = path.join(PROJECT_ROOT, 'cookies.json');
const BACKUP_PATH = path.join(PROJECT_ROOT, 'cookies.json.bak');

// Required fields only (everything else is discarded)
const ALLOWED_FIELDS = new Set([
  'name',
  'value',
  'domain',
  'path',
  'secure',
  'httpOnly'
]);

function fatal(msg) {
  console.error(`\n[✗] ${msg}\n`);
  process.exit(1);
}

// --- Validate input ---
if (!fs.existsSync(COOKIE_PATH)) {
  fatal('cookies.json not found in project directory');
}

// --- Read cookies ---
let raw;
try {
  raw = JSON.parse(fs.readFileSync(COOKIE_PATH, 'utf8'));
} catch (e) {
  fatal('cookies.json is not valid JSON');
}

if (!Array.isArray(raw)) {
  fatal('cookies.json must contain a JSON array');
}

// --- Sanitize ---
const cleaned = raw.map((cookie, idx) => {
  if (!cookie.name || !cookie.value || !cookie.domain) {
    fatal(`Invalid cookie at index ${idx} (missing name/value/domain)`);
  }

  const clean = {};
  for (const key of Object.keys(cookie)) {
    if (ALLOWED_FIELDS.has(key)) {
      clean[key] = cookie[key];
    }
  }

  // Defaults (defensive)
  if (!clean.path) clean.path = '/';
  if (typeof clean.secure !== 'boolean') clean.secure = true;

  return clean;
});

// --- Verify MoodleSession exists ---
if (!cleaned.some(c => c.name === 'MoodleSession')) {
  fatal('MoodleSession cookie not found — are you logged in?');
}

// --- Backup original ---
fs.copyFileSync(COOKIE_PATH, BACKUP_PATH);

// --- Write sanitized version ---
fs.writeFileSync(
  COOKIE_PATH,
  JSON.stringify(cleaned, null, 2)
);

console.log('[✓] cookies.json sanitised successfully');
console.log(`[i] Backup saved as ${path.basename(BACKUP_PATH)}`);
