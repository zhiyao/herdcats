import { screenshotUrl } from '@/lib/screenshots';
import styles from './AppScreenshot.module.css';

type Screen = 'spaces' | 'timeline-light' | 'timeline-dark' | 'terminal-compose' | 'voice' | 'bridge-setup' | 'approval';

export function AppScreenshot({ screen, alt, caption }: { screen: Screen; alt: string; caption: string }) {
  const latest = { spaces: '01-spaces', 'terminal-compose': '09-compose', voice: '10-voice' } as const;
  const id = latest[screen as keyof typeof latest];
  const src = id ? screenshotUrl(id, true) : `/assets/app/${screen}.webp`;
  return (
    <figure className={styles.figure}>
      <a href={src} target="_blank" rel="noopener noreferrer" aria-label={`Open full screenshot: ${caption}`}>
        <img src={src} alt={alt} width={id ? 1320 : 600} height={id ? 2868 : 1304} loading="lazy" decoding="async" className={styles.image} />
      </a>
      <figcaption className={styles.caption}>{caption}</figcaption>
    </figure>
  );
}
