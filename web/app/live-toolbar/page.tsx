'use client';

import { useEffect, useRef, useState } from 'react';
import Link from 'next/link';
import styles from './page.module.css';

type Key = { label: string; token: string };
type Modifier = 'ctrl' | 'alt' | 'shift';
const arrows: Key[] = [{ label: '←', token: 'left' }, { label: '↑', token: 'up' }, { label: '↓', token: 'down' }, { label: '→', token: 'right' }];
const navigation: Key[] = [{ label: 'Home', token: 'home' }, { label: 'End', token: 'end' }, { label: 'Pg↑', token: 'pageup' }, { label: 'Pg↓', token: 'pagedown' }];
const editing: Key[] = [{ label: 'Del', token: 'delete' }, { label: 'Ins', token: 'insert' }, { label: 'Bksp', token: 'backspace' }, { label: '↵', token: 'enter' }];
const functions: Key[] = Array.from({ length: 12 }, (_, i) => ({ label: `F${i + 1}`, token: `f${i + 1}` }));
const modifierOrder: Modifier[] = ['ctrl', 'alt', 'shift'];

export default function LiveToolbarPage() {
  const [armed, setArmed] = useState<Modifier[]>([]);
  const [keysOpen, setKeysOpen] = useState(false);
  const [arrowOpen, setArrowOpen] = useState(false);
  const [lastSent, setLastSent] = useState('Nothing sent');
  const [mode, setMode] = useState<'Live' | 'Compose' | 'Voice'>('Live');
  const arrowTimer = useRef<ReturnType<typeof setTimeout> | null>(null);
  const didLongPress = useRef(false);
  const arrowButton = useRef<HTMLButtonElement>(null);
  const arrowMenu = useRef<HTMLDivElement>(null);
  const keysButton = useRef<HTMLButtonElement>(null);
  const keysMenu = useRef<HTMLDivElement>(null);
  const railRef = useRef<HTMLDivElement>(null);

  useEffect(() => {
    if (!armed.length) return;
    function onKey(event: globalThis.KeyboardEvent) {
      if (event.target instanceof HTMLElement && event.target.closest('input, select, textarea, button')) return;
      const named: Record<string, string> = { ArrowUp: 'up', ArrowDown: 'down', ArrowLeft: 'left', ArrowRight: 'right', Backspace: 'backspace', Delete: 'delete', Enter: 'enter', Tab: 'tab', Escape: 'esc' };
      const key = named[event.key] ?? (/^[a-z0-9\[\]_-]$/i.test(event.key) ? event.key.toLowerCase() : null);
      if (!key) return;
      event.preventDefault();
      setLastSent([...modifierOrder.filter(item => armed.includes(item)), key].join('+'));
      setArmed([]); setKeysOpen(false); setArrowOpen(false);
    }
    window.addEventListener('keydown', onKey);
    return () => window.removeEventListener('keydown', onKey);
  }, [armed]);

  useEffect(() => () => { if (arrowTimer.current) clearTimeout(arrowTimer.current); }, []);
  useEffect(() => {
    if (!keysOpen && !arrowOpen) return;
    function outside(event: PointerEvent) {
      if (!(event.target instanceof Node)) return;
      if ([arrowButton, arrowMenu, keysButton, keysMenu, railRef].some(ref => ref.current?.contains(event.target as Node))) return;
      setKeysOpen(false); setArrowOpen(false);
    }
    function escape(event: globalThis.KeyboardEvent) { if (event.key === 'Escape') { setKeysOpen(false); setArrowOpen(false); } }
    document.addEventListener('pointerdown', outside); document.addEventListener('keydown', escape);
    return () => { document.removeEventListener('pointerdown', outside); document.removeEventListener('keydown', escape); };
  }, [keysOpen, arrowOpen]);

  function toggle(modifier: Modifier) { setArmed(current => current.includes(modifier) ? current.filter(item => item !== modifier) : [...current, modifier]); }
  function send(key: Key) {
    setLastSent([...modifierOrder.filter(item => armed.includes(item)), key.token].join('+'));
    setArmed([]); setKeysOpen(false); setArrowOpen(false);
  }
  function stopTimer() { if (arrowTimer.current) clearTimeout(arrowTimer.current); arrowTimer.current = null; }
  function openArrows() { setArrowOpen(true); setKeysOpen(false); }
  function changeMode(next: 'Compose' | 'Voice') { setMode(next); setKeysOpen(false); setArrowOpen(false); setArmed([]); }
  function row(keys: Key[]) { return keys.map(key => <button type="button" key={key.token} onClick={() => send(key)} aria-label={`Simulate ${key.label}`}>{key.label}</button>); }

  return <main className={styles.page}>
    <header className={styles.siteHeader}><Link href="/" className={styles.back}>← Herdcats</Link><span className={styles.prototype}>INTERACTIVE DESIGN STUDY / 01</span></header>
    <section className={styles.intro} aria-labelledby="title">
      <div><p className={styles.eyebrow}>PANE INPUT · LIVE MODE</p><h1 id="title">More keys.<br /><span>Less hunting.</span></h1>
        <p className={styles.lead}>Use the iPhone keyboard for text. Keep frequent terminal keys in one place, and open Keys for the less common ones. Only F1–F12 scrolls sideways.</p>
        <div className={styles.principles}><span><b>01</b> Fixed fast rail</span><span><b>02</b> One-tap Keys drawer</span><span><b>03</b> Stack modifiers</span></div>
      </div>
      <div className={styles.notes}><h2>Recommended behavior</h2>
        <p><strong>The rail stays still.</strong> Esc, Tab, Up, Ctrl, Alt, and Keys keep the same positions so they are easy to find by touch.</p>
        <p><strong>Keys opens a compact drawer.</strong> Arrows, navigation, editing keys, Shift, and F1–F12 appear above the rail. Only the ordered function-key row scrolls sideways.</p>
        <p><strong>Modifiers combine.</strong> Tap Ctrl, Alt, and/or Shift, then a key. Their highlights clear after that key.</p>
        <p><strong>This page is a simulation.</strong> The iOS toolbar now uses the same key layout. Herdr sends the key tokens; each agent decides how to respond.</p>
      </div>
    </section>
    <section className={styles.workbench} aria-labelledby="workbench-title"><div className={styles.workbenchHeader}><div><p className={styles.eyebrow}>TRY THE INTERACTION</p><h2 id="workbench-title">Live pane preview</h2></div></div>
      <div className={styles.previewWrap}><div className={styles.phone}>
        <div className={styles.statusBar}><span>9:41</span><span>●●● ▰</span></div>
        <div className={styles.paneHeader}><span className={styles.chevron}>‹</span><div><strong>auth-service</strong><small>main · pane 2 of 3</small></div><span className={styles.headerMore}>•••</span></div>
        <div className={styles.paneSwitch}><span>shell</span><span className={styles.selectedPane}>codex · working</span><span>tests</span></div>
        <div className={styles.terminal}><p className={styles.dim}>$ herdr pane view auth-service:2</p><p>Updating auth middleware and tests.</p><p className={styles.green}>✓ Read src/auth/session.ts</p><p className={styles.green}>✓ Added expiry check</p><p className={styles.dim}>Waiting for input…</p><div className={styles.menu}><p><span>›</span> Accept suggested change</p><p>  Review diff</p><p>  Continue editing</p></div><p className={styles.cursorLine}>❯ <i /></p></div>
        {mode === 'Live' ? <div className={styles.inputDock}>
          {keysOpen && <div id="extra-keys" ref={keysMenu} className={styles.keysDrawer} aria-label="Extra keyboard keys">
            <div className={styles.keyGrid}>{row(arrows)}</div><div className={styles.keyGrid}>{row(navigation)}</div><div className={styles.keyGrid}>{row(editing)}</div>
            <div className={styles.keyGrid}><button type="button" className={armed.includes('shift') ? styles.keyActive : ''} aria-pressed={armed.includes('shift')} onClick={() => toggle('shift')}>Shift</button></div>
            <div className={styles.functionScroll} aria-label="Function keys, swipe horizontally">{row(functions)}</div>
          </div>}
          {arrowOpen && <div ref={arrowMenu} className={styles.arrowMenu} role="menu" aria-label="Arrow keys"><div className={styles.arrowPad}>{arrows.map(key => <button type="button" role="menuitem" key={key.token} onClick={() => send(key)} aria-label={`Simulate ${key.token} arrow`}>{key.label}</button>)}</div></div>}
          <div ref={railRef} className={styles.rail}>
            <button type="button" className={styles.esc} onClick={() => send({ label: 'Esc', token: 'esc' })}>Esc</button>
            <button type="button" onClick={() => send({ label: 'Tab', token: 'tab' })}>Tab</button>
            <button type="button" ref={arrowButton} aria-label="Up arrow. Tap to send Up; long press for all directions." aria-haspopup="menu" aria-expanded={arrowOpen}
              onPointerDown={event => { if (event.button !== 0) return; didLongPress.current = false; stopTimer(); arrowTimer.current = setTimeout(() => { didLongPress.current = true; openArrows(); }, 480); }}
              onPointerUp={event => { if (event.button !== 0) return; stopTimer(); if (!didLongPress.current) send(arrows[1]); }}
              onPointerCancel={stopTimer}
              onContextMenu={event => { event.preventDefault(); stopTimer(); didLongPress.current = true; openArrows(); }}
              onKeyDown={event => { if (event.key === 'Enter' || event.key === ' ') { event.preventDefault(); send(arrows[1]); } else if (event.key === 'F10' && event.shiftKey) { event.preventDefault(); openArrows(); } }}
            >↑<span className={styles.arrowCaret}>⌃</span></button>
            <button type="button" className={armed.includes('ctrl') ? styles.railActive : ''} aria-pressed={armed.includes('ctrl')} onClick={() => toggle('ctrl')}>Ctrl</button>
            <button type="button" className={armed.includes('alt') ? styles.railActive : ''} aria-pressed={armed.includes('alt')} onClick={() => toggle('alt')}>Alt<span className={styles.altOption}>⌥</span></button>
            <button type="button" ref={keysButton} className={keysOpen ? styles.railActive : ''} aria-expanded={keysOpen} aria-controls="extra-keys" onClick={() => { setKeysOpen(value => !value); setArrowOpen(false); }}>Keys</button>
            <span className={styles.railDivider} /><button type="button" onClick={() => changeMode('Voice')} aria-label="Preview Voice">◉</button><button type="button" onClick={() => changeMode('Compose')} aria-label="Preview Compose">⌨</button>
          </div>
        </div> : <div className={styles.modeDock}><div><strong>{mode}</strong><small>{mode === 'Compose' ? 'Drafts stay separate from Live input.' : 'Dictation becomes a Compose draft.'}</small></div><button type="button" onClick={() => setMode('Live')}>Back to Live</button></div>}
        <div className={styles.homeIndicator} />
      </div>
      <aside className={styles.previewAside}><div className={styles.simulation}><span>SIMULATION ONLY</span><strong>Last key: <code>{lastSent}</code></strong><p>This preview changes local UI state. It has no SSH connection and sends nothing to a pane.</p></div>
        <div className={styles.tryList}><h3>Try these</h3><button type="button" onClick={() => { setKeysOpen(true); setArrowOpen(false); }}>Open Keys <span>↗</span></button><button type="button" onClick={() => { setKeysOpen(true); setArrowOpen(false); setArmed(['ctrl', 'alt']); }}>Try Ctrl + Alt + key <span>↗</span></button></div>
        <div className={styles.callout}><span>DESIGN DETAIL</span><p>The rail stays fixed. The F-key row scrolls inside the drawer, with the next key peeking in at the edge.</p></div>
      </aside></div>
    </section>
    <footer className={styles.footer}>Interactive preview of the Live input surface in <code>PaneDetailView</code>. This web page sends no pane input.</footer>
  </main>;
}
