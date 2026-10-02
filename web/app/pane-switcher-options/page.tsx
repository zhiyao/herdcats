'use client';

import { Fragment, useState } from 'react';
import styles from './page.module.css';

type Direction = 'cards' | 'rail' | 'shelf';
type Pane = { id: string; title: string; agent: string; tabId: string; status: 'working' | 'blocked' | 'idle'; updated: string };

const panes: Pane[] = [
  { id: 'auth', title: 'auth-service', agent: 'Codex', tabId: 'build', status: 'working', updated: 'now' },
  { id: 'tests', title: 'api-tests', agent: 'Claude', tabId: 'build', status: 'blocked', updated: '2m ago' },
  { id: 'scripts', title: 'scripts', agent: 'Command line', tabId: 'ops', status: 'idle', updated: '8m ago' },
];

const directions: { id: Direction; number: string; name: string; summary: string; detail: string }[] = [
  {
    id: 'cards', number: '01', name: 'Floating glass cards',
    summary: 'Give each expanded card and collapsed chip its own translucent surface.',
    detail: 'Closest to today’s switcher. Selection stays clear, and the cards still read as separate panes.',
  },
  {
    id: 'rail', number: '02', name: 'One segmented rail',
    summary: 'Put the panes inside a shared glass rail, separated by vertical hairlines.',
    detail: 'Echoes the new Live toolbar. The expanded and collapsed states feel like the same control.',
  },
  {
    id: 'shelf', number: '03', name: 'Quiet glass shelf',
    summary: 'Use one translucent shelf with a soft selection highlight and a divider between tabs.',
    detail: 'The tab boundary stays visible in both states. Expand sits freely at the edge.',
  },
];

function LiveRail() {
  return <div className={styles.liveRail} aria-label="Revised Live toolbar proposal for context">
    {['Esc', 'Tab', '↑', 'Ctrl', '⌘'].map((key) => <span key={key}>{key}</span>)}
    <i className={styles.liveDivider} aria-hidden="true" />
    <span><svg viewBox="0 0 24 24" aria-label="Voice"><rect x="9" y="3" width="6" height="12" rx="3" /><path d="M6 11a6 6 0 0 0 12 0M12 17v4m-4 0h8" /></svg></span>
    <span><svg viewBox="0 0 24 24" aria-label="Keyboard"><rect x="2" y="5" width="20" height="14" rx="2" /><path d="M5 9h1m3 0h1m3 0h1m3 0h1M5 12h1m3 0h1m3 0h1M7 16h10" /></svg></span>
  </div>;
}

function StatePreview({ compact, selectedPane, onPaneSelect }: {
  compact: boolean;
  selectedPane: string;
  onPaneSelect: (id: string) => void;
}) {
  const selected = panes.find((pane) => pane.id === selectedPane) ?? panes[0];

  return <div className={styles.stateBlock}>
    <div className={styles.stateLabel}><span>{compact ? 'COLLAPSED' : 'EXPANDED'}</span><small>{compact ? 'quick switch' : 'pane details'}</small></div>
    <div className={styles.appFrame}>
      <div className={styles.appNav}><span className={styles.back}>‹</span><div><strong>{selected.title}</strong><small>~/workspaces/website</small></div><span className={styles.more}>···</span></div>
      <div className={`${styles.switcher} ${compact ? styles.compact : styles.expanded}`}>
        <div className={styles.switcherScroll}>
          <div className={styles.paneRow}>
            {panes.map((pane, index) => <Fragment key={pane.id}>
              {index > 0 && panes[index - 1].tabId !== pane.tabId && <span className={styles.tabDivider} aria-label="New tab" role="separator" />}
              <button type="button" onClick={() => onPaneSelect(pane.id)} aria-pressed={selectedPane === pane.id} className={`${styles.pane} ${selectedPane === pane.id ? styles.activePane : ''}`}>
                <span className={`${styles.status} ${styles[pane.status]}`} />
                <span className={styles.paneContent}><strong>{pane.title}</strong>{!compact && <span className={styles.paneDetails}><em>{pane.agent}</em><small>{pane.updated}</small></span>}</span>
              </button>
            </Fragment>)}
            {!compact && <button type="button" className={styles.addPane} aria-label="Add pane preview" title="Add pane">+</button>}
          </div>
        </div>
        {compact && <button type="button" className={styles.expand} aria-label="Expand pane cards preview" title="Expanded state is shown above">⌄</button>}
        <span className={styles.dragHandle} aria-hidden="true" />
      </div>
      <div className={styles.output}>
        <p><span>❯</span> Running tests for the sign-in flow</p>
        <p className={styles.outputMuted}>✓ Found the session handler</p>
        <p className={styles.outputMuted}>Updating auth routes…</p>
      </div>
      <div className={styles.input}><LiveRail /></div>
    </div>
  </div>;
}

function ConceptCard({ direction, selected, onSelect }: {
  direction: typeof directions[number];
  selected: boolean;
  onSelect: () => void;
}) {
  const [selectedPane, setSelectedPane] = useState('auth');

  return <article className={`${styles.card} ${styles[direction.id]} ${selected ? styles.selectedCard : ''}`}>
    <div className={styles.cardHead}>
      <div className={styles.cardMeta}><span>{direction.number} / DIRECTION</span>{selected && <span className={styles.selectedTag}>SELECTED</span>}</div>
      <h2>{direction.name}</h2>
      <p>{direction.summary}</p>
    </div>
    <div className={styles.states}>
      <StatePreview compact={false} selectedPane={selectedPane} onPaneSelect={setSelectedPane} />
      <StatePreview compact selectedPane={selectedPane} onPaneSelect={setSelectedPane} />
    </div>
    <div className={styles.cardFoot}>
      <p>{direction.detail}</p>
      <button type="button" onClick={onSelect} aria-pressed={selected}>{selected ? 'Selected for comparison' : `Choose direction ${direction.number}`}</button>
    </div>
  </article>;
}

export default function PaneSwitcherOptionsPage() {
  const [selected, setSelected] = useState<Direction>('cards');

  return <main className={styles.page}>
    <div className={styles.shell}>
      <header className={styles.header}><div className={styles.brand}><span className={styles.brandMark}>H<span>✦</span></span><span>Herdcats <small>/ DESIGN STUDY</small></span></div><span className={styles.headerNote}>PANE SWITCHER · EXPANDED + COLLAPSED</span></header>
      <section className={styles.intro}>
        <p className={styles.eyebrow}>A MATCH FOR THE NEW LIVE RAIL</p>
        <h1>The pane switcher,<br /><em>through glass.</em></h1>
        <p>Compare the top selector in both states. Floating glass cards stay separate, with a divider at each tab boundary. Expand sits freely at the edge. The Live rail below has one divider before Voice. Tap a pane to see its selection state.</p>
      </section>
      <section className={styles.grid} aria-label="Three translucent pane switcher directions">
        {directions.map((direction) => <ConceptCard key={direction.id} direction={direction} selected={selected === direction.id} onSelect={() => setSelected(direction.id)} />)}
      </section>
      <footer className={styles.footer}>Direction 1 is selected for the iOS pane switcher. The revised Live divider is also in iOS.</footer>
    </div>
  </main>;
}
