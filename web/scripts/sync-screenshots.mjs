import {cp, mkdir, readFile} from 'node:fs/promises';
import {fileURLToPath} from 'node:url';
import path from 'node:path';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..');
const campaign = JSON.parse(await readFile(path.join(root, 'ios/app-store-images/campaign.json'), 'utf8'));
for (const appearance of ['', 'light']) {
  const destination = path.join(root, 'web/public/assets/screenshots', appearance);
  await mkdir(destination, {recursive: true});
  for (const slide of campaign.slides) {
    const name = `${slide.id}.png`;
    await cp(path.join(root, 'assets/screenshots', appearance, name), path.join(destination, name));
  }
}
