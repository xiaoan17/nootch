#!/usr/bin/env node
// Renders og.html into the social share images in docs/media/:
//   og-image.png        1200x630  Open Graph / Twitter card
//   social-preview.png  1280x640  GitHub repository social preview
// Captured at deviceScaleFactor 2, then downscaled so text stays crisp.
//
// Env: PLAYWRIGHT_PATH (a node_modules/playwright dir, if `playwright` is not resolvable).
import { createRequire } from 'node:module';
import { execFileSync } from 'node:child_process';
import { mkdtempSync, rmSync, statSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import os from 'node:os';

const here = dirname(fileURLToPath(import.meta.url));
const media = join(resolve(here, '../..'), 'docs/media');
const TARGETS = [
  { name: 'og-image.png', w: 1200, h: 630 },
  { name: 'social-preview.png', w: 1280, h: 640 },
];

const require = createRequire(import.meta.url);
let playwright;
try { playwright = require('playwright'); }
catch { playwright = require(process.env.PLAYWRIGHT_PATH || 'playwright'); }

const tmp = mkdtempSync(join(os.tmpdir(), 'nootch-og-'));
const browser = await playwright.chromium.launch({ channel: 'chrome' });
try {
  for (const { name, w, h } of TARGETS) {
    const page = await browser.newPage({ viewport: { width: w, height: h }, deviceScaleFactor: 2 });
    await page.goto(pathToFileURL(join(here, 'og.html')).href + `?w=${w}&h=${h}`);
    await page.evaluate(() => document.fonts.ready);
    await page.waitForLoadState('networkidle');
    const raw = join(tmp, name);
    await page.screenshot({ path: raw });
    await page.close();
    const out = join(media, name);
    execFileSync('sips', ['-z', String(h), String(w), raw, '--out', out], { stdio: 'ignore' });
    console.log(`${out}  ${(statSync(out).size / 1024).toFixed(0)} KB`);
  }
} finally {
  await browser.close();
  rmSync(tmp, { recursive: true, force: true });
}
