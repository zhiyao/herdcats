import {copyFile, mkdir, mkdtemp, rm, readFile} from 'node:fs/promises';
import path from 'node:path';
import {fileURLToPath} from 'node:url';
import {parseArgs} from 'node:util';

// Renders App Store creatives and/or the site OG card.
// Usage:
//   node render-creative.mjs --og-only
//   node render-creative.mjs [--input=<dir with 03_spaces.png and 06_agents.png>] [--output=<dir>]
const packageDir = path.dirname(fileURLToPath(import.meta.url));
const iosDir = path.dirname(packageDir);
const repoDir = path.dirname(iosDir);
const {values} = parseArgs({
  options: {
    input: {type: 'string'},
    output: {type: 'string'},
    'og-only': {type: 'boolean', default: false},
  },
});
const ogOnly = values['og-only'] === true;
const input = path.resolve(values.input || path.join(iosDir, 'maestro/screenshots-output/iPhone_17_Pro_Max'));
const parent = path.resolve(values.output || path.join(iosDir, 'maestro/app-store-output'));
const ogPath = path.join(repoDir, 'web/public/og.png');

const {bundle} = await import('@remotion/bundler');
const {renderStill, selectComposition, openBrowser} = await import('@remotion/renderer');
const pngSize = async file => {
  const bytes = await readFile(file);
  if (bytes.subarray(0, 8).toString('hex') !== '89504e470d0a1a0a') throw new Error(`${file}: invalid PNG.`);
  return {width: bytes.readUInt32BE(16), height: bytes.readUInt32BE(20)};
};

let inputProps = {};
const cache = path.join(packageDir, '.cache');
await mkdir(cache, {recursive: true});
const work = await mkdtemp(path.join(cache, 'creative-'));
const publicDir = path.join(work, 'public');
await mkdir(publicDir, {recursive: true});
await copyFile(path.join(repoDir, 'web/public/assets/logo.png'), path.join(publicDir, 'logo.png'));

if (!ogOnly) {
  const sizes = {
    main: await pngSize(path.join(input, '03_spaces.png')),
    second: await pngSize(path.join(input, '06_agents.png')),
  };
  for (const [name, {width, height}] of Object.entries(sizes)) {
    if (width < 600 || height / width < 1.9 || height / width > 2.3) {
      throw new Error(`${name}: expected a full portrait iPhone capture, got ${width}x${height}.`);
    }
  }
  inputProps = {sources: {main: 'spaces.png', second: 'agents.png'}, sizes};
  await copyFile(path.join(input, '03_spaces.png'), path.join(publicDir, 'spaces.png'));
  await copyFile(path.join(input, '06_agents.png'), path.join(publicDir, 'agents.png'));
  await mkdir(parent, {recursive: true});
}

const output = ogOnly
  ? null
  : await mkdtemp(path.join(parent, `creative-${new Date().toISOString().replace(/[:.]/g, '-')}-`));

const jobs = ogOnly
  ? [['OgCard', ogPath]]
  : [
      ['ProductHeader', path.join(output, 'product-page-header.png')],
      ['SearchResult', path.join(output, 'search-results.png')],
    ];

let browser;
try {
  const serveUrl = await bundle({
    entryPoint: path.join(packageDir, 'src/creative-index.jsx'),
    publicDir,
    outDir: path.join(work, 'bundle'),
    webpackOverride: c => ({
      ...c,
      resolve: {...c.resolve, extensions: ['.ts', '.tsx', ...(c.resolve?.extensions || [])]},
    }),
  });
  browser = await openBrowser('chrome');
  for (const [id, file] of jobs) {
    const composition = await selectComposition({serveUrl, id, inputProps, puppeteerInstance: browser});
    await renderStill({
      serveUrl,
      composition,
      inputProps,
      output: file,
      imageFormat: 'png',
      frame: 0,
      puppeteerInstance: browser,
    });
    console.log(`${id}: ${file}`);
  }
  if (ogOnly) {
    const {width, height} = await pngSize(ogPath);
    if (width !== 1200 || height !== 630) {
      throw new Error(`og.png: expected 1200x630, got ${width}x${height}`);
    }
  }
} finally {
  if (browser) await browser.close({silent: true});
  await rm(work, {recursive: true, force: true});
}
