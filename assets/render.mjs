// Render cguard diagrams to PNG with headless Chromium.
// Usage: node render.mjs            (all)
//        node render.mjs hero       (one)
//
// Heights are fixed per diagram, not measured. Measuring the document picks up
// the absolutely positioned glow/grid layers (they extend past the layout box),
// and neutralising height:100% during measurement collapses flex layouts that
// rely on margin-top:auto. The layout is authored at a fixed size; keep it fixed.
import { chromium } from 'playwright';
import path from 'node:path';
import fs from 'node:fs';
import { fileURLToPath } from 'node:url';

const here = path.dirname(fileURLToPath(import.meta.url));

const shots = [
  { name: 'hero', file: 'hero.html', w: 1280, h: 640 },
  { name: 'what-eats', file: 'what-eats.html', w: 1280, h: 673 },
  { name: 'how-it-works', file: 'how-it-works.html', w: 1280, h: 560 },
  { name: 'zh-hero', file: 'zh-hero.html', w: 1280, h: 640 },
  { name: 'zh-what-eats', file: 'zh-what-eats.html', w: 1280, h: 690 },
];

const only = process.argv[2];
const list = only ? shots.filter((s) => s.name === only) : shots;
if (only && list.length === 0) {
  console.error(`unknown diagram: ${only}`);
  process.exit(1);
}

const browser = await chromium.launch();
for (const s of list) {
  const file = path.join(here, s.file);
  if (!fs.existsSync(file)) {
    console.log(`  skip ${s.name} (no ${s.file})`);
    continue;
  }

  const page = await browser.newPage({
    viewport: { width: s.w, height: s.h },
    deviceScaleFactor: 2,
  });
  await page.goto('file://' + file, { waitUntil: 'load' });
  await page.evaluate(() => document.fonts.ready);
  await page.waitForTimeout(140);

  const out = path.join(here, `${s.name}.png`);
  await page.screenshot({ path: out, clip: { x: 0, y: 0, width: s.w, height: s.h } });
  const kb = (fs.statSync(out).size / 1024).toFixed(0);
  console.log(`  ${s.name}.png  ${s.w}x${s.h} @2x  ${kb} KB`);
  await page.close();
}
await browser.close();
