'use client';

import { useRef, useState } from 'react';
import styles from './page.module.css';

type Direction = 'rail' | 'clusters' | 'strip';

const directions: { id: Direction; number: string; name: string; idea: string; detail: string }[] = [
  {
    id: 'rail',
    number: '01',
    name: 'One glass rail',
    idea: 'One shared capsule, with a divider before Voice and Keyboard.',
    detail: 'Closest to your Play / Stop reference. Everything reads as one toolbar.',
  },
  {
    id: 'clusters',
    number: '02',
    name: 'Split by purpose',
    idea: 'Terminal keys and input modes sit in two connected groups.',
    detail: 'The small gap makes Voice and Compose easier to find with one thumb.',
  },
  {
    id: 'strip',
    number: '03',
    name: 'Quiet bottom strip',
    idea: 'A wider, flatter bar uses one divider before the mode actions.',
    detail: 'The terminal stays visually dominant, with the lightest control chrome.',
  },
];

function Icon({ name }: { name: 'photo' | 'mic' | 'keyboard' | 'arrow' }) {
  if (name === 'photo') return <svg viewBox="0 0 24 24" aria-hidden="true"><rect x="3" y="4" width="18" height="16" rx="2" /><circle cx="8" cy="9" r="1.5" /><path d="m4 17 5-5 3 3 3-4 5 6" /></svg>;
  if (name === 'mic') return <svg viewBox="0 0 24 24" aria-hidden="true"><rect x="9" y="3" width="6" height="12" rx="3" /><path d="M6 11a6 6 0 0 0 12 0M12 17v4m-4 0h8" /></svg>;
  if (name === 'keyboard') return <svg viewBox="0 0 24 24" aria-hidden="true"><rect x="2" y="5" width="20" height="14" rx="2" /><path d="M5 9h1m3 0h1m3 0h1m3 0h1m3 0h1M5 12h1m3 0h1m3 0h1M7 16h10" /></svg>;
  return <svg viewBox="0 0 24 24" aria-hidden="true"><path d="M12 19V5m-6 6 6-6 6 6" /></svg>;
}

function ConceptCard({ direction, selected, onSelect }: {
  direction: typeof directions[number];
  selected: boolean;
  onSelect: () => void;
}) {
  const [draft, setDraft] = useState('Could you check the failing sign-in test?');
  const [armed, setArmed] = useState(false);
  const [notice, setNotice] = useState('');
  const photoRef = useRef<HTMLInputElement>(null);

  const key = (label: string, action: () => void, extra = '') => (
    <button type="button" className={`${styles.key} ${extra}`} onClick={action} aria-label={label === '↑' ? 'Up arrow' : label} key={label}>{label}</button>
  );

  const terminalKeys = [
    key('Esc', () => setNotice('Escape key preview')),
    key('Tab', () => setNotice('Tab key preview')),
    key('↑', () => setNotice('Up arrow preview')),
    key('Ctrl', () => { setArmed(!armed); setNotice(!armed ? 'Control armed' : 'Control cleared'); }, armed ? styles.armed : ''),
    <button type="button" className={styles.key} aria-label="Command unavailable" title="Command is unavailable for this terminal" disabled key="command">⌘</button>,
  ];
  const modeKeys = [
    <button type="button" className={styles.key} aria-label="Start voice recording" onClick={() => setNotice('Voice would open the recording bar')} key="voice"><Icon name="mic" /></button>,
    <button type="button" className={styles.key} aria-label="Open Compose" onClick={() => setNotice('Compose is shown below')} key="compose"><Icon name="keyboard" /></button>,
  ];

  return (
    <article className={`${styles.card} ${styles[direction.id]} ${selected ? styles.selected : ''}`}>
      <div className={styles.cardHead}>
        <span className={styles.number}>{direction.number} / CONCEPT</span>
        {selected && <span className={styles.selectedTag}>SELECTED</span>}
        <h2>{direction.name}</h2>
        <p>{direction.idea}</p>
      </div>

      <div className={styles.demo}>
        <div className={styles.paneTop}><span className={styles.paneDot} /><strong>Codex</strong><span>auth-service</span><span className={styles.paneMenu}>···</span></div>
        <div className={styles.terminal}>
          <span className={styles.terminalLabel}>PANE OUTPUT</span>
          <p><span>❯</span> Fix the sign-in flow and run tests</p>
          <p className={styles.dim}>Inspecting authentication routes…</p>
          <p className={styles.dim}>✓ Found the session handler</p>
          <p><span>❯</span> <i className={styles.cursor} /></p>
        </div>
        <div className={styles.surfaces}>
          <div className={styles.surfaceLabel}><span>LIVE</span><small>terminal keys</small></div>
          {direction.id === 'clusters' ? (
            <div className={styles.liveClusters}>
              <div className={styles.glassGroup}>{terminalKeys}</div>
              <div className={styles.glassGroup}>{modeKeys}</div>
            </div>
          ) : (
            <div className={styles.glassGroup}>{terminalKeys}<span className={direction.id === 'strip' ? styles.groupGap : styles.inputDivider} aria-hidden="true" />{modeKeys}</div>
          )}

          <div className={`${styles.surfaceLabel} ${styles.composeLabel}`}><span>COMPOSE</span><small>review before sending</small></div>
          <div className={styles.compose}>
            <input ref={photoRef} type="file" accept="image/*" className={styles.fileInput} onChange={(event) => setNotice(event.target.files?.[0]?.name ? `Attached: ${event.target.files?.[0]?.name}` : '')} />
            <button type="button" className={styles.bareIcon} aria-label="Attach image" onClick={() => photoRef.current?.click()}><Icon name="photo" /></button>
            <div className={styles.composeField}>
              <textarea aria-label="Message draft" rows={2} value={draft} onChange={(event) => setDraft(event.target.value)} placeholder="Message the agent…" />
              <button type="button" className={styles.bareIcon} aria-label="Dictate message" onClick={() => setNotice('Voice would open the recording bar')}><Icon name="mic" /></button>
              {draft.trim() && <button type="button" className={styles.send} aria-label="Send preview message" onClick={() => setNotice('Preview only — no message sent')}><Icon name="arrow" /></button>}
            </div>
          </div>
          <p className={styles.notice} aria-live="polite">{notice || 'Tap a control to preview its state.'}</p>
        </div>
      </div>

      <div className={styles.cardFoot}>
        <p>{direction.detail}</p>
        <button type="button" onClick={onSelect} aria-pressed={selected}>{selected ? 'Selected for comparison' : `Choose concept ${direction.number}`}</button>
      </div>
    </article>
  );
}

export default function PaneBarOptionsPage() {
  const [selected, setSelected] = useState<Direction>('clusters');

  return (
    <main className={styles.page}>
      <div className={styles.shell}>
        <header className={styles.header}>
          <div className={styles.brand}><span className={styles.brandMark}>H<span>✦</span></span><span>Herdcats <small>/ DESIGN STUDY</small></span></div>
          <span className={styles.headerNote}>PANE INPUT · 3 DIRECTIONS</span>
        </header>
        <div className={styles.intro}>
          <p className={styles.eyebrow}>LIVE TOOLBAR + COMPOSE</p>
          <h1>Glass as one surface.<br /><em>Controls with room to breathe.</em></h1>
          <p>Three ways to bring back translucency without a circle around every action. The selected glass rail now has one divider between terminal keys and Voice/Keyboard. Image and Voice stay plain icons in Compose.</p>
        </div>
        <div className={styles.grid} aria-label="Three pane bar design directions">
          {directions.map((direction) => <ConceptCard key={direction.id} direction={direction} selected={selected === direction.id} onSelect={() => setSelected(direction.id)} />)}
        </div>
        <footer className={styles.footer}>Web mockups only. These controls do not connect to Herdr or change the iOS app.</footer>
      </div>
    </main>
  );
}
