import Link from 'next/link';
import styles from './page.module.css';

export const metadata = {
  title: 'Herdcats — Design studies',
  robots: { index: false },
};

const STUDIES: { href: string; title: string; summary: string }[] = [
  { href: '/live-toolbar', title: 'Live toolbar', summary: 'Fixed key rail and Keys drawer for Live mode.' },
  { href: '/live-ui', title: 'Live UI', summary: 'Live typing first, rich input when needed.' },
  { href: '/input-modes', title: 'Input modes', summary: 'Decision guide for pane input: Live, Compose, and Voice.' },
  { href: '/command-pane', title: 'Command pane', summary: 'Prototype layouts for terminal shortcuts and slash commands.' },
  { href: '/pane-bar-options', title: 'Pane bar options', summary: 'Glass pane bar variations.' },
  { href: '/pane-switcher-options', title: 'Pane switcher options', summary: 'Switching panes across tabs.' },
  { href: '/progress-spinner-options', title: 'Progress & spinners', summary: 'Consolidating progress views.' },
  { href: '/progress-consolidation.html', title: 'Progress audit (static)', summary: 'Standalone progress view audit.' },
  { href: '/offline-demo.html', title: 'Offline demo proposal', summary: 'Under review; not an approved design.' },
];

export default function StudiesPage() {
  return (
    <div className={styles.page}>
      <main className={styles.shell}>
        <Link href="/" className={styles.back}>← Herdcats</Link>
        <h1 className={styles.title}>Design studies</h1>
        <p className={styles.lead}>
          Working prototypes and explorations. These simulate the app locally and are not shipped features.
        </p>
        <ul className={styles.list}>
          {STUDIES.map((study) => (
            <li key={study.href}>
              <a href={study.href} className={styles.item}>
                <strong>{study.title}</strong>
                <span>{study.summary}</span>
              </a>
            </li>
          ))}
        </ul>
      </main>
    </div>
  );
}
