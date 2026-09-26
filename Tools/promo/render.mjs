#!/usr/bin/env node
// Renders promo.html frame by frame with Playwright + Google Chrome, then encodes
// docs/media/nootch-promo.mp4, nootch-promo.gif and nootch-promo-poster.png with ffmpeg.
//
//   node Tools/promo/render.mjs                 # full render
//   node Tools/promo/render.mjs --stills 4,9,13 # only write preview PNGs for those seconds
//
// Env: FRAMES_DIR (default $TMPDIR/nootch-promo-frames), FFMPEG (default ffmpeg),
//      PLAYWRIGHT_PATH (a node_modules/playwright dir, if `playwright` is not resolvable).
import { createRequire } from 'node:module';
import { execFileSync } from 'node:child_process';
import { mkdirSync, rmSync, statSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import os from 'node:os';

const here = dirname(fileURLToPath(import.meta.url));
const repo = resolve(here, '../..');
const media = join(repo, 'docs/media');
const framesDir = process.env.FRAMES_DIR || join(os.tmpdir(), 'nootch-promo-frames');
const ffmpeg = process.env.FFMPEG || 'ffmpeg';
const FPS = 30;
const WORKERS = 4;
const GIF_RANGE = [3.0, 11.0]; // slide-out, hover card, rolling numbers
const POSTER_AT = 9.0;

const require = createRequire(import.meta.url);
let playwright;
try { playwright = require('playwright'); }
catch { playwright = require(process.env.PLAYWRIGHT_PATH || 'playwright'); }

const args = process.argv.slice(2);
const stillsArg = args.includes('--stills') ? args[args.indexOf('--stills') + 1] : null;

async function openPage(browser) {
  const page = await browser.newPage({ viewport: { width: 960, height: 540 }, deviceScaleFactor: 2 });
  await page.goto(pathToFileURL(join(here, 'promo.html')).href);
  await page.evaluate(() => document.fonts.ready);
  await page.waitForLoadState('networkidle');
  return page;
}

async function shoot(page, t, path, type = 'jpeg') {
  await page.evaluate(t => window.renderFrame(t), t);
  await page.screenshot({ path, type, ...(type === 'jpeg' ? { quality: 95 } : {}) });
}

const size = p => (statSync(p).size / 1024 / 1024).toFixed(2) + ' MB';
const run = (...a) => execFileSync(ffmpeg, ['-y', '-loglevel', 'error', ...a], { stdio: 'inherit' });

const browser = await playwright.chromium.launch({ channel: 'chrome' });
try {
  if (stillsArg) {
    mkdirSync(framesDir, { recursive: true });
    const page = await openPage(browser);
    for (const s of stillsArg.split(',').map(Number)) {
      const out = join(framesDir, `still-${s.toFixed(2)}.png`);
      await shoot(page, s, out, 'png');
      console.log(out);
    }
  } else {
    rmSync(framesDir, { recursive: true, force: true });
    mkdirSync(framesDir, { recursive: true });
    const duration = await (await openPage(browser)).evaluate(() => window.PROMO_DURATION);
    const total = Math.round(duration * FPS);
    let next = 0;
    await Promise.all(Array.from({ length: WORKERS }, async () => {
      const page = await openPage(browser);
      while (next < total) {
        const f = next++;
        await shoot(page, f / FPS, join(framesDir, `f${String(f).padStart(5, '0')}.jpg`));
        if (f % 90 === 0) console.log(`frame ${f}/${total}`);
      }
    }));

    mkdirSync(media, { recursive: true });
    const mp4 = join(media, 'nootch-promo.mp4');
    run('-framerate', String(FPS), '-i', join(framesDir, 'f%05d.jpg'),
      '-vf', 'scale=in_range=pc:out_range=tv,format=yuv420p',
      '-c:v', 'libx264', '-preset', 'slow', '-crf', '18', '-pix_fmt', 'yuv420p',
      '-profile:v', 'high', '-movflags', '+faststart', mp4);

    const gif = join(media, 'nootch-promo.gif');
    const [a, b] = GIF_RANGE;
    const filters = 'fps=20,scale=800:-1:flags=lanczos';
    const palette = join(framesDir, 'palette.png');
    run('-ss', String(a), '-t', String(b - a), '-i', mp4, '-vf', `${filters},palettegen=stats_mode=full`, palette);
    run('-ss', String(a), '-t', String(b - a), '-i', mp4, '-i', palette, '-lavfi',
      `${filters}[x];[x][1:v]paletteuse=dither=sierra2_4a:diff_mode=rectangle`, gif);

    const page = await openPage(browser);
    const poster = join(media, 'nootch-promo-poster.png');
    await shoot(page, POSTER_AT, poster, 'png');

    for (const p of [mp4, gif, poster]) console.log(`${p}  ${size(p)}`);
  }
} finally {
  await browser.close();
}
