import {readFile, mkdir, mkdtemp, writeFile, rm, access} from 'node:fs/promises';
import path from 'node:path';
import {fileURLToPath} from 'node:url';
import {spawnSync} from 'node:child_process';
import {createHash} from 'node:crypto';
import {parseArgs} from 'node:util';

const packageDir = path.dirname(fileURLToPath(import.meta.url));
const iosDir = path.dirname(packageDir);
const usage = `Usage: ios/bin/screenshots-app-store [options]

  --target=<name>       all (default), iphone-6.3, iphone-6.5, iphone-6.9
  --capture             Capture the campaign sources first
  --device=<UDID>       Override capture device
  --input=<directory>   Raw captures for a single target
  --iphone-input=<dir>  Override iPhone source folder for all targets
  --only=<id>           One slide across selected sizes, e.g. 01-spaces
  --output=<directory>  Parent for a fresh run directory
  --preview             Open the comparison contact sheet
  --help                Show this help

Default sources: ios/maestro/screenshots-output/iPhone_17_Pro_Max
Default output:  ios/maestro/app-store-output/<run>/<target>/*.png
One-time setup: npm ci --prefix ios/app-store-images
`;

function run(command, args, options = {}) {
  const result = spawnSync(command, args, {stdio: 'inherit', ...options});
  if (result.error) throw result.error;
  if (result.status !== 0) throw new Error(`${command} failed (${result.signal || result.status}).`);
  return result.stdout;
}

function pngInfo(bytes, name) {
  if (bytes.length < 33 || bytes.subarray(0, 8).toString('hex') !== '89504e470d0a1a0a'
      || bytes.toString('ascii', 12, 16) !== 'IHDR') throw new Error(`${name}: invalid PNG.`);
  return {width: bytes.readUInt32BE(16), height: bytes.readUInt32BE(20), bitDepth: bytes[24], colorType: bytes[25]};
}

function pngHasTRNS(bytes) {
  for (let offset = 8; offset + 8 <= bytes.length;) {
    const length = bytes.readUInt32BE(offset);
    const type = bytes.toString('ascii', offset + 4, offset + 8);
    if (type === 'tRNS') return true;
    if (type === 'IEND') return false;
    offset += 12 + length;
  }
  return false;
}

function pngSize(bytes, name, family) {
  const {width, height} = pngInfo(bytes, name);
  const ratio = height / width;
  const validRatio = ratio >= 1.9 && ratio <= 2.3;
  if (width < 600 || height <= width || !validRatio) {
    throw new Error(`${name}: expected a full portrait ${family} capture, got ${width}x${height}.`);
  }
  return {width, height};
}

function assertExportPng(bytes, name, width, height) {
  const info = pngInfo(bytes, name);
  if (info.width !== width || info.height !== height) {
    throw new Error(`${name}: expected ${width}x${height}, got ${info.width}x${info.height}.`);
  }
  if (info.bitDepth !== 8 || info.colorType !== 2 || pngHasTRNS(bytes)) {
    throw new Error(`${name}: expected opaque 8-bit RGB.`);
  }
}

const escapeHtml = text => String(text).replace(/[&<>"']/g, c => ({'&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;'}[c]));
const html = (title, body) => `<!doctype html><html lang="en"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>${escapeHtml(title)}</title><style>body{margin:32px;background:#0a0b0e;color:#F8F8F8;font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,sans-serif}h1{font-size:28px;font-weight:700;letter-spacing:-0.5px}h2{font-size:18px;margin-top:40px;color:#ABE0B6;font-weight:600}.row{display:flex;flex-wrap:wrap;align-items:flex-start;gap:24px}figure{margin:0;width:min(340px,100%)}img{display:block;width:100%;border-radius:14px;box-shadow:0 12px 32px rgba(0,0,0,0.7),0 0 0 1px rgba(255,255,255,0.08)}figcaption{padding:12px 0;font-size:13px;color:#8e8e93}a{color:#0edcd5;text-decoration:none}a:hover{text-decoration:underline}nav{display:flex;gap:24px;flex-wrap:wrap;margin-bottom:24px;padding:12px 16px;background:#26343D;border-radius:10px}</style>${body}</html>`;

async function main() {
  const {values} = parseArgs({options: {
    capture: {type: 'boolean'}, device: {type: 'string'}, input: {type: 'string'},
    'iphone-input': {type: 'string'},
    target: {type: 'string', default: 'all'}, only: {type: 'string'},
    output: {type: 'string'}, preview: {type: 'boolean'}, help: {type: 'boolean'},
  }});
  if (values.help) { console.log(usage); return; }
  if (Number(process.versions.node.split('.')[0]) < 22) throw new Error('Node.js 22 or newer is required.');
  const explicitInputs = values.input || values['iphone-input'];
  if (values.capture && explicitInputs) throw new Error('--capture and input overrides are mutually exclusive.');
  if (values.device && !values.capture) throw new Error('--device requires --capture.');
  if (values.target === 'all' && (values.device || values.input)) throw new Error('For all targets use --iphone-input, or choose one --target with --input / --device.');
  if (values.input && values['iphone-input']) throw new Error('Use either --input or family input overrides, not both.');

  const campaign = JSON.parse(await readFile(path.join(packageDir, 'campaign.json'), 'utf8'));
  if (typeof campaign.background !== 'string' || !/^#[0-9A-Fa-f]{6}$/.test(campaign.background)) {
    throw new Error('campaign.json needs one shared #RRGGBB background.');
  }
  const targetNames = values.target === 'all' ? campaign.defaultTargets : [values.target];
  for (const name of targetNames) {
    if (!Object.hasOwn(campaign.targets, name)) throw new Error(`Unknown target: ${name}. Available: all, ${Object.keys(campaign.targets).join(', ')}`);
    const target = campaign.targets[name];
    if (!/^[a-z0-9.-]+$/.test(name) || !Object.hasOwn(campaign.sources, target.family)
        || !Number.isInteger(target.width) || !Number.isInteger(target.height) || target.width < 1 || target.height < 1) {
      throw new Error(`Invalid target configuration: ${name}`);
    }
  }
  const families = [...new Set(targetNames.map(name => campaign.targets[name].family))];
  for (const family of Object.keys(campaign.sources)) {
    if (values[`${family}-input`] && !families.includes(family)) {
      throw new Error(`--${family}-input does not apply to the selected target.`);
    }
  }
  const slides = campaign.slides.filter(slide => !values.only || slide.id === values.only);
  if (!slides.length || slides.length > 10) throw new Error(`Choose 1-10 slides. Available: ${campaign.slides.map(s => s.id).join(', ')}`);
  const ids = new Set();
  for (const slide of slides) {
    if (!/^[a-z0-9-]+$/.test(slide.id) || ids.has(slide.id)) throw new Error(`Invalid or duplicate slide ID: ${slide.id}`);
    ids.add(slide.id);
    for (const source of [slide.source, ...(slide.secondarySource ? [slide.secondarySource] : [])]) {
      if (typeof source !== 'string' || !/^[a-zA-Z0-9_-]+\.png$/.test(source)) throw new Error(`Invalid source filename: ${source}`);
    }
    if (slide.layout === 'stacked' && !slide.secondarySource) throw new Error(`Stacked layout needs secondarySource: ${slide.id}`);
    if (!['device', 'closeup', 'stacked', 'tilted'].includes(slide.layout)) throw new Error(`Invalid layout: ${slide.id}`);
    if (![slide.headline, slide.accent].every(s => typeof s === 'string' && s.length)) throw new Error(`Missing headline: ${slide.id}`);
  }

  let bundle, renderStill, selectComposition, openBrowser;
  try {
    ({bundle} = await import('@remotion/bundler'));
    ({renderStill, selectComposition, openBrowser} = await import('@remotion/renderer'));
  } catch (error) {
    throw new Error(`Install dependencies: npm ci --prefix ios/app-store-images\n${error.message}`);
  }

  const selectedSources = [...new Set(slides.flatMap(slide => [slide.source, ...(slide.secondarySource ? [slide.secondarySource] : [])]))];
  const inputs = Object.fromEntries(families.map(family => [family, path.resolve(values.input || values[`${family}-input`]
    || path.join(iosDir, 'maestro/screenshots-output', campaign.sources[family].folder))]));
  const captureDevices = {};
  if (values.capture) {
    const flows = selectedSources.map(source => source.replace(/\.png$/, '.yaml'));
    for (const flow of flows) {
      if (!/^[0-9]/.test(flow)) throw new Error(`Capture must use a numbered flow: ${flow}`);
      try { await access(path.join(iosDir, 'maestro/screenshots', flow)); }
      catch { throw new Error(`No current Maestro flow: ${flow}`); }
    }
    const flowPaths = flows.map(flow => path.join(iosDir, 'maestro/screenshots', flow));
    const family = families[0];
    let name = campaign.sources[family].device;
    if (values.device) {
      const listing = JSON.parse(run('xcrun', ['simctl', 'list', 'devices', 'available', '--json'], {encoding: 'utf8', stdio: ['ignore', 'pipe', 'inherit']}));
      const device = Object.values(listing.devices).flat().find(d => d.isAvailable
        && (d.udid.toLowerCase() === values.device.toLowerCase() || d.name === values.device));
      if (!device || !device.name.startsWith('iPhone')) throw new Error(`No available iPhone matches --device.`);
      name = device.name;
      captureDevices[family] = {name, udid: device.udid};
    } else captureDevices[family] = {name};
    if (/[\\/]/.test(name)) throw new Error('Simulator name must not contain path separators.');
    run(path.join(iosDir, 'bin/screenshots'), [`--device=${values.device || name}`, ...flowPaths]);
    inputs[family] = path.join(iosDir, 'maestro/screenshots-output', name.replaceAll(' ', '_'));
  }

  // Snapshot every family before rendering. Missing sources fail the entire campaign.
  const sources = new Map();
  for (const family of families) for (const source of selectedSources) {
    const filename = path.join(inputs[family], source);
    let bytes;
    try { bytes = await readFile(filename); }
    catch { throw new Error(`Missing capture: ${filename}\nRun --capture or provide --input / --${family}-input.`); }
    sources.set(`${family}/${source}`, {...pngSize(bytes, filename, family), file: filename,
      sha256: createHash('sha256').update(bytes).digest('hex'), bytes});
  }

  const parent = path.resolve(values.output || path.join(iosDir, 'maestro/app-store-output'));
  await mkdir(parent, {recursive: true});
  const output = await mkdtemp(path.join(parent, `${new Date().toISOString().replace(/[:.]/g, '-')}-`));
  const cache = path.join(packageDir, '.cache');
  await mkdir(cache, {recursive: true});
  const work = await mkdtemp(path.join(cache, 'render-'));
  const publicDir = path.join(work, 'public');
  let browser;
  const exports = [];
  const sourceRecord = ({file, width, height, sha256}) => ({file, width, height, sha256});
  try {
    for (const family of families) await mkdir(path.join(publicDir, family), {recursive: true});
    for (const [source, data] of sources) await writeFile(path.join(publicDir, source), data.bytes);
    const serveUrl = await bundle({entryPoint: path.join(packageDir, 'src/index.jsx'), publicDir, outDir: path.join(work, 'bundle')});
    browser = await openBrowser('chrome');
    for (const name of targetNames) {
      const target = campaign.targets[name];
      const destination = path.join(output, name);
      await mkdir(destination);
      console.log(`Rendering ${slides.length} ${name} images (${target.width}x${target.height})`);
      const records = [];
      for (const slide of slides) {
        const source = sources.get(`${target.family}/${slide.source}`);
        const secondary = sources.get(`${target.family}/${slide.secondarySource}`);
        const inputProps = {slide: {...slide, source: `${target.family}/${slide.source}`,
          ...(secondary ? {secondarySource: `${target.family}/${slide.secondarySource}`} : {})},
          sourceWidth: source.width, sourceHeight: source.height,
          secondarySize: secondary ? {width: secondary.width, height: secondary.height} : null,
          width: target.width, height: target.height, family: target.family,
          background: campaign.background};
        const composition = await selectComposition({serveUrl, id: 'AppStoreScreenshot', inputProps, puppeteerInstance: browser});
        const filename = `${slide.id}.png`;
        const exported = path.join(destination, filename);
        await renderStill({serveUrl, composition, inputProps, output: exported, imageFormat: 'png', frame: 0, puppeteerInstance: browser});
        assertExportPng(await readFile(exported), `${name}/${filename}`, target.width, target.height);
        records.push({file: filename, slide, source: sourceRecord(source), ...(secondary ? {secondarySource: sourceRecord(secondary)} : {})});
        console.log(`  ${name}/${filename}`);
      }
      const manifest = {status: 'complete', createdAt: new Date().toISOString(), target: name, ...target,
        locale: campaign.locale, remotionVersion: '4.0.523', captureDevice: captureDevices[target.family] || null,
        input: inputs[target.family], images: records};
      await writeFile(path.join(destination, 'manifest.json'), JSON.stringify(manifest, null, 2) + '\n');
      await writeFile(path.join(destination, 'index.html'), html(target.description,
        `<a href="../index.html">← All sizes</a><h1>${escapeHtml(target.description)}</h1><p>${target.width} x ${target.height}</p><div class="row">${records.map(r => `<figure><a href="${r.file}"><img src="${r.file}" alt="${escapeHtml(r.slide.headline + ' ' + r.slide.accent)}"></a><figcaption>${r.file}</figcaption></figure>`).join('')}</div>`));
      exports.push(manifest);
    }
    const comparison = `<h1>HerdrCat App Store Campaign</h1><p>${slides.length} shared slides / ${exports.length} sizes / ${escapeHtml(campaign.locale)}</p><nav>${exports.map(e => `<a href="${e.target}/index.html">${escapeHtml(e.description)}</a>`).join('')}</nav>${slides.map(slide => `<section><h2>${escapeHtml(slide.id)} / ${escapeHtml(slide.headline + ' ' + slide.accent)}</h2><div class="row">${exports.map(e => `<figure><a href="${e.target}/${slide.id}.png"><img loading="lazy" src="${e.target}/${slide.id}.png" alt="${escapeHtml(e.description + ': ' + slide.headline)}"></a><figcaption>${escapeHtml(e.description)} / ${e.width} x ${e.height}</figcaption></figure>`).join('')}</div></section>`).join('')}`;
    await writeFile(path.join(output, 'index.html'), html('HerdrCat App Store Campaign', comparison));
    await writeFile(path.join(output, 'manifest.json'), JSON.stringify({status: 'complete', createdAt: new Date().toISOString(),
      locale: campaign.locale, slides, targets: exports.map(e => ({target: e.target, width: e.width, height: e.height, manifest: `${e.target}/manifest.json`}))}, null, 2) + '\n');
    console.log(`Complete: ${output}\nPreview: ${path.join(output, 'index.html')}`);
  } catch (error) {
    console.error(`Incomplete campaign retained: ${output} (no complete root manifest).`);
    throw error;
  } finally {
    if (browser) await browser.close({silent: true});
    await rm(work, {recursive: true, force: true});
  }
  if (values.preview) {
    try { run('open', [path.join(output, 'index.html')]); }
    catch (error) { console.warn(`Artwork is complete; preview could not open: ${error.message}`); }
  }
}

main().catch(error => { console.error(`[herdrcat] ${error.message}`); process.exitCode = 1; });
