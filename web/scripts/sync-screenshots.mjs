import {createHash} from 'node:crypto';
import {cp, mkdir, readFile, writeFile} from 'node:fs/promises';
import {fileURLToPath} from 'node:url';
import path from 'node:path';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..');
const campaign = JSON.parse(await readFile(path.join(root, 'ios/app-store-images/campaign.json'), 'utf8'));
const versions = {};
for (const appearance of ['', 'light']) {
  const destination = path.join(root, 'web/public/assets/screenshots', appearance);
  await mkdir(destination, {recursive: true});
  for (const slide of campaign.slides) {
    const name = `${slide.id}.png`;
    versions[`${appearance ? `${appearance}/` : ''}${slide.id}`] = createHash('sha256').update(await readFile(path.join(root, 'assets/screenshots', appearance, name))).digest('hex').slice(0, 12);
    await cp(path.join(root, 'assets/screenshots', appearance, name), path.join(destination, name));
  }
}

await writeFile(path.join(root, 'web/public/assets/screenshots/versions.json'), JSON.stringify(versions, null, 2) + '\n');
