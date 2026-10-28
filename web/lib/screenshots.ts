import versions from '@/public/assets/screenshots/versions.json';

export function screenshotUrl(id: string, light = false) {
  const key = `${light ? 'light/' : ''}${id}`;
  const version = versions[key as keyof typeof versions];
  if (!version) throw new Error(`Missing screenshot: ${key}`);
  return `/assets/screenshots/${key}.png?v=${version}`;
}
