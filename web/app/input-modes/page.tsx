'use client';

import { useState } from 'react';
import Link from 'next/link';
import styles from './page.module.css';

type Path = {
  number: string;
  name: string;
  eyebrow: string;
  summary: string;
  steps: string[];
  gain: string;
  cost: string;
  fit: string;
  recommended?: boolean;
};

const paths: Path[] = [
  {
    number: '01',
    name: 'Measure, then build',
    eyebrow: 'RECOMMENDED',
    summary: 'Prove the live typing path on an iPhone before building the Compose / Live switch.',
    steps: [
      'Test typing, Backspace, slash menus, and Return in disposable agent panes.',
      'Measure key-to-screen delay over the actual SSH route.',
      'Build the segmented switch once the live path meets the target.',
    ],
    gain: 'Best chance of a Live mode that feels responsive and keeps Compose reliable.',
    cost: 'The visible switch arrives after a short technical validation step.',
    fit: 'Choose this when quality matters more than seeing the switch immediately.',
    recommended: true,
  },
  {
    number: '02',
    name: 'Build an experimental switch',
    eyebrow: 'FASTER UI FEEDBACK',
    summary: 'Add Compose / Live now, keep Compose as the default, and label Live as experimental.',
    steps: [
      'Add the persistent segmented control above pane input.',
      'Route Live keys through an ordered queue using Herdr pane commands.',
      'Try it on real networks, then tune or replace the input path.',
    ],
    gain: 'You can try the two modes in the app sooner and give direct UX feedback.',
    cost: 'Live may lag or behave differently across agent TUIs until measured and refined.',
    fit: 'Choose this for a private prototype you will test before release.',
  },
  {
    number: '03',
    name: 'Explore a streaming terminal',
    eyebrow: 'DEEPER ENGINEERING',
    summary: 'Investigate a persistent SSH terminal attached through the Herdr CLI before adding the switch.',
    steps: [
      'Validate Herdr attach in a disposable pane over a long-lived SSH PTY.',
      'Prove ordered input, output, reconnect, and pane ownership.',
      'Build the segmented UI on that streaming foundation.',
    ],
    gain: 'Closest to the feel of a traditional SSH terminal if command-by-command input is too slow.',
    cost: 'More implementation and testing work; the attach behavior still needs proof.',
    fit: 'Choose this if the measured command path misses the live-input target.',
  },
];

export default function InputModesPage() {
  const [selected, setSelected] = useState(0);
  const active = paths[selected];

  return (
    <main className={styles.page}>
      <div className={styles.glow} aria-hidden="true" />
      <div className={styles.shell}>
        <header className={styles.topbar}>
          <Link href="/" className={styles.brand} aria-label="Herdcats home">
            <img src="/assets/logo.svg" alt="" width={34} height={34} />
            <span>Herdcats</span>
          </Link>
          <span className={styles.documentTag}>INPUT MODES / DECISION GUIDE</span>
        </header>

        <section className={styles.hero} aria-labelledby="page-title">
          <div className={styles.kicker}><span className={styles.kickerLine} /> THREE WAYS FORWARD</div>
          <h1 id="page-title">How should we build <em>live input?</em></h1>
          <p>
            Compose gives you a local draft. Live would send keys straight to the agent TUI.
            The segmented control is planned; the question is how much we validate before it ships.
          </p>
          <div className={styles.evidence}>
            <span className={styles.evidenceDot} />
            <strong>What we know:</strong> Herdr showed shell text and a Codex slash menu before Return.
            iPhone-to-SSH typing latency has not been measured yet.
          </div>
        </section>

        <section className={styles.options} aria-label="Three implementation paths">
          {paths.map((path, index) => (
            <button
              key={path.number}
              type="button"
              onClick={() => setSelected(index)}
              className={`${styles.option} ${selected === index ? styles.selected : ''}`}
              aria-pressed={selected === index}
            >
              <span className={styles.optionTop}>
                <span className={styles.optionNumber}>{path.number}</span>
                <span className={`${styles.badge} ${path.recommended ? styles.recommended : ''}`}>{path.eyebrow}</span>
              </span>
              <span className={styles.optionTitle}>{path.name}</span>
              <span className={styles.optionSummary}>{path.summary}</span>
              <span className={styles.optionFooter}>View this path <span aria-hidden="true">↗</span></span>
            </button>
          ))}
        </section>

        <section className={styles.detail} aria-live="polite" aria-labelledby="detail-title">
          <div className={styles.detailHeading}>
            <div>
              <span className={styles.detailLabel}>PATH {active.number}</span>
              <h2 id="detail-title">{active.name}</h2>
            </div>
            {active.recommended && <span className={styles.pick}>OUR PICK</span>}
          </div>
          <div className={styles.detailGrid}>
            <div className={styles.steps}>
              <h3>What happens next</h3>
              <ol>
                {active.steps.map((step) => <li key={step}>{step}</li>)}
              </ol>
            </div>
            <div className={styles.tradeoffs}>
              <div><span>YOU GET</span><p>{active.gain}</p></div>
              <div><span>TRADEOFF</span><p>{active.cost}</p></div>
              <div><span>BEST FIT</span><p>{active.fit}</p></div>
            </div>
          </div>
        </section>

        <footer className={styles.footer}>
          <span>Decision guide for Herdcats pane input · September 2026</span>
          <span>Compose remains the default in every path.</span>
        </footer>
      </div>
    </main>
  );
}
