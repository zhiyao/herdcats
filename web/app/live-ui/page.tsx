'use client';

import { useEffect, useRef, useState } from 'react';
import Link from 'next/link';
import styles from './page.module.css';

type Concept = {
  name: string;
  label: string;
  summary: string;
  pros: string[];
  cons: string[];
  voice: string;
  photo: string;
};

const concepts: Concept[] = [
  {
    name: 'Keep the mode switch',
    label: 'Smallest change',
    summary: 'Live is for direct TUI keys. Switch to the familiar Compose view whenever you need a reviewed message, dictation, or a photo.',
    pros: ['Preserves the composer you already like.', 'Very clear which action sends terminal keys.', 'Least new UI and implementation work.'],
    cons: ['Voice and photos take a mode switch.', 'A long Compose draft can pull you out of the live flow.'],
    voice: 'Switch to Compose → dictate → review the text → Send.',
    photo: 'Switch to Compose → attach a photo → review → Send through the existing supported path.',
  },
  {
    name: 'Single-row Live toolbar',
    label: 'Recommended',
    summary: 'One row holds Esc, Tab, Up, Ctrl, ⌘ (unavailable), Voice, and Keyboard. Keyboard opens Compose directly; tapping terminal output opens Live typing.',
    pros: ['Keeps the Live controls in one row.', 'Voice starts immediately and still gives you a transcript to edit.', 'Compose is available without recording first.'],
    cons: ['The Compose bar takes more height while editing.', 'Modifier and chord behavior needs explicit testing in agent TUIs.'],
    voice: 'Tap Voice → speak → tap the checkmark → edit the one-row draft (up to six rows) → Send explicitly.',
    photo: 'After recording, the photo icon sits left of the message bubble. Voice and Send are inside it.',
  },
  {
    name: 'Two input zones',
    label: 'Most immediate',
    summary: 'Show the Live key field and a compact staged-message tray together. Voice and photos enter the tray; only its Send button submits them.',
    pros: ['Live keys and rich input are always one tap away.', 'A staged draft remains visible while watching the TUI.'],
    cons: ['Takes space from the terminal, especially with the keyboard open.', 'Two nearby input paths can be easy to confuse.'],
    voice: 'Tap the mic in the tray → review the transcript there → Send.',
    photo: 'Tap the photo button in the tray → inspect the attachment → Send.',
  },
];

type DemoAction = 'voice' | 'photo' | 'voiceRecording' | 'voiceDraft' | null;

export default function LiveUiPage() {
  const [selected, setSelected] = useState(1);
  const [action, setAction] = useState<DemoAction>(null);
  const [mode, setMode] = useState<'Live' | 'Compose'>('Live');
  const [transcript, setTranscript] = useState('');
  const [photoName, setPhotoName] = useState<string | null>(null);
  const [previewSent, setPreviewSent] = useState(false);
  const [keyboardActive, setKeyboardActive] = useState(false);
  const [armedModifier, setArmedModifier] = useState<'Ctrl' | null>(null);
  const keyboardRef = useRef<HTMLInputElement>(null);
  const draftRef = useRef<HTMLTextAreaElement>(null);
  const photoRef = useRef<HTMLInputElement>(null);
  const active = concepts[selected];

  useEffect(() => {
    const field = draftRef.current;
    if (!field || action !== 'voiceDraft') return;
    field.style.height = 'auto';
    field.style.height = `${Math.min(Math.max(field.scrollHeight, 36), 136)}px`;
  }, [action, transcript]);

  function selectConcept(index: number) {
    setSelected(index);
    setAction(null);
    setMode('Live');
    setTranscript('');
    setPhotoName(null);
    setPreviewSent(false);
    setKeyboardActive(false);
    setArmedModifier(null);
  }

  function openVoice() {
    setKeyboardActive(false);
    keyboardRef.current?.blur();
    setAction('voiceRecording');
    setPreviewSent(false);
  }

  function openLiveKeyboard() {
    setAction(null);
    setKeyboardActive(true);
    keyboardRef.current?.focus();
  }

  function openCompose() {
    setKeyboardActive(false);
    keyboardRef.current?.blur();
    setAction('voiceDraft');
    requestAnimationFrame(() => draftRef.current?.focus());
  }

  return (
    <main className={styles.page}>
      <div className={styles.shell}>
        <header className={styles.topbar}>
          <Link href="/" className={styles.brand}><img src="/assets/logo.png" alt="" width={30} height={30} /> Herdcats</Link>
          <span className={styles.topLabel}>PANE INPUT · DESIGN STUDY</span>
        </header>

        <section className={styles.intro}>
          <p className={styles.eyebrow}>THREE UI DIRECTIONS</p>
          <h1>Live typing first.<br /><span>Rich input when you need it.</span></h1>
          <p className={styles.lead}>The agent TUI remains the main interaction. Dictation needs a transcript you can check; photos need an attachment preview. Neither should pretend to be a terminal keystroke.</p>
        </section>

        <section className={styles.choiceGrid} aria-label="Choose a UI direction">
          {concepts.map((concept, index) => (
            <button key={concept.name} type="button" onClick={() => selectConcept(index)} aria-pressed={selected === index} className={`${styles.choice} ${selected === index ? styles.activeChoice : ''}`}>
              <span className={styles.choiceMeta}><span>0{index + 1}</span><span>{concept.label}</span></span>
              <strong>{concept.name}</strong>
              <span className={styles.choiceSummary}>{concept.summary}</span>
              <span className={styles.choiceLink}>Explore layout <span aria-hidden="true">↗</span></span>
            </button>
          ))}
        </section>

        <section className={styles.study} aria-live="polite">
          <div className={styles.previewColumn}>
            <div className={styles.sectionHead}><div><p className={styles.eyebrow}>INTERACTIVE SKETCH · 0{selected + 1}</p><h2>{active.name}</h2></div><span className={styles.sketchTag}>Concept, not app behavior</span></div>
            <div className={styles.appPreview}>
              <div className={styles.paneHeader}><span className={styles.backMark}>‹</span><div><strong>Codex · auth-service</strong><small>Pane #2 · Working</small></div><span className={styles.paneMore}>···</span></div>
              <div className={styles.terminal} onClick={selected === 1 ? openLiveKeyboard : undefined} onKeyDown={selected === 1 ? (event) => { if (event.key === 'Enter') openLiveKeyboard(); } : undefined} role={selected === 1 ? 'button' : undefined} tabIndex={selected === 1 ? 0 : undefined} aria-label={selected === 1 ? 'Tap terminal output to type Live' : undefined}>
                <div className={styles.terminalMeta}><span className={styles.liveDot} /> REMOTE PANE <span>SSH</span></div>
                <p><span className={styles.prompt}>❯</span> Fix the sign-in flow and run tests</p>
                <p className={styles.muted}>Inspecting authentication routes…</p>
                <p className={styles.muted}>✓ Found the session handler</p>
                <p><span className={styles.prompt}>❯</span> <span className={styles.cursor} /></p>
                {selected === 1 && previewSent && <p className={styles.keyboardStatus}>Preview only · nothing sent to the pane</p>}
                {selected === 1 && keyboardActive && <p className={styles.keyboardStatus}>Live keyboard focused in this preview · no keys are sent</p>}
                {selected === 1 && <input ref={keyboardRef} className={styles.keyboardCapture} aria-label="Live keyboard preview" autoCapitalize="off" autoCorrect="off" onBlur={() => setKeyboardActive(false)} onChange={(event) => { event.currentTarget.value = ''; setArmedModifier(null); }} />}
              </div>
              <div className={styles.inputArea}>
                {selected === 0 && <div className={styles.segment} aria-label="Illustrative input mode switch"><button type="button" className={mode === 'Compose' ? styles.segmentActive : ''} onClick={() => { setMode('Compose'); setAction(null); }}>Compose</button><button type="button" className={mode === 'Live' ? styles.segmentActive : ''} onClick={() => { setMode('Live'); setAction(null); }}>Live</button></div>}
                {selected === 1 && action === null && <div className={styles.singleKeyRow} aria-label="Single-row Live controls"><button type="button" aria-label="Escape key preview">Esc</button><button type="button" aria-label="Tab key preview">Tab</button><button type="button" aria-label="Up arrow key preview">↑</button><button type="button" aria-label="Arm Control modifier" aria-pressed={armedModifier === 'Ctrl'} className={armedModifier === 'Ctrl' ? styles.keyArmed : ''} onClick={() => setArmedModifier(armedModifier === 'Ctrl' ? null : 'Ctrl')}>Ctrl</button><button type="button" aria-label="Command key unavailable for this terminal" title="Command chords are unavailable for this terminal" disabled>⌘</button><button type="button" aria-label="Open voice command" onClick={openVoice}><svg viewBox="0 0 24 24" aria-hidden="true"><rect x="9" y="3" width="6" height="12" rx="3" /><path d="M6 11a6 6 0 0 0 12 0M12 17v4m-4 0h8" /></svg></button><button type="button" aria-label="Compose message" onClick={openCompose}><svg viewBox="0 0 24 24" aria-hidden="true"><rect x="2" y="5" width="20" height="14" rx="2" /><path d="M5 9h1m3 0h1m3 0h1m3 0h1M5 12h1m3 0h1m3 0h1M7 16h10" /></svg></button></div>}
                {selected === 1 && action === 'voiceRecording' && <div className={styles.recordingBar} aria-label="Recording controls"><span><i aria-hidden="true" /> Recording preview</span><button type="button" className={styles.recordingDone} aria-label="Finish recording" onClick={() => { setTranscript((draft) => draft ? `${draft}\nCould you check the failing sign-in test?` : 'Could you check the failing sign-in test?'); setAction('voiceDraft'); }}><svg viewBox="0 0 24 24" aria-hidden="true"><path d="m5 12 4.5 4.5L19 7" /></svg></button></div>}
                {selected === 1 && action === 'voiceDraft' && <div className={styles.composeBar} aria-label="Compose draft controls">
                  {photoName && <div className={styles.photoChip}>▧ {photoName}<button type="button" onClick={() => { setPhotoName(null); if (photoRef.current) photoRef.current.value = ''; }} aria-label="Remove attached photo">×</button></div>}
                  <div className={styles.composeLine}>
                    <input ref={photoRef} type="file" accept="image/*" className={styles.photoInput} aria-label="Attach photo" onChange={(event) => { setPhotoName(event.target.files?.[0]?.name ?? null); setPreviewSent(false); }} />
                    <button type="button" className={styles.photoTrigger} onClick={() => photoRef.current?.click()} aria-label="Attach image"><svg viewBox="0 0 24 24" aria-hidden="true"><rect x="3" y="4" width="18" height="16" rx="2" /><circle cx="8" cy="9" r="1.5" /><path d="m4 17 5-5 3 3 3-4 5 6" /></svg></button>
                    <div className={styles.messageBubble}>
                      <textarea ref={draftRef} rows={1} className={styles.composeField} aria-label="Editable Compose draft" placeholder="Message the agent…" value={transcript} onChange={(event) => { setTranscript(event.target.value); setPreviewSent(false); }} />
                      <button type="button" onClick={openVoice} aria-label="Start dictation in Compose"><svg viewBox="0 0 24 24" aria-hidden="true"><rect x="9" y="3" width="6" height="12" rx="3" /><path d="M6 11a6 6 0 0 0 12 0M12 17v4m-4 0h8" /></svg></button>
                      {transcript.trim().length > 0 && <button type="button" className={styles.composeSend} onClick={() => { setPreviewSent(true); setAction(null); }} aria-label="Send Compose message preview"><svg viewBox="0 0 24 24" aria-hidden="true"><path d="m3 11 18-8-7 18-3-8-8-2Z" /><path d="M11 13 21 3" /></svg></button>}
                    </div>
                  </div>
                </div>}
                {selected !== 1 && (selected !== 0 || mode === 'Live') && <div className={styles.liveRow}><span className={styles.liveBadge}>LIVE</span><span>Type into remote pane</span><span className={styles.keyHint}>↵</span></div>}
                {selected !== 1 && (selected !== 0 || mode === 'Live') && <div className={styles.keyRow}><span>esc</span><span>tab</span><span>←</span><span>↓</span><span>↑</span><span>→</span><span>return</span></div>}
                {(selected === 2 || (selected === 0 && mode === 'Compose')) && <div className={styles.composeTray}><span>Draft a message for the agent…</span><div><button type="button" onClick={() => setAction('voice')} aria-label="Preview dictation">◉ Mic</button><button type="button" onClick={() => setAction('photo')} aria-label="Preview photo">▧ Photo</button><span className={styles.sendPill}>Send</span></div></div>}
                {selected === 0 && mode === 'Live' && <p className={styles.switchNote}>Switch to Compose for voice or photos.</p>}
              </div>
              {selected !== 1 && action && <div className={styles.inlinePreview}><button type="button" onClick={() => setAction(null)} aria-label="Close preview">×</button><strong>{action === 'voice' ? 'Dictation preview' : 'Photo preview'}</strong><p>{action === 'voice' ? 'Review the transcript before Send.' : 'Review the attachment before Send.'}</p></div>}
            </div>
            <div className={styles.demoActions}><span>Try the flow:</span><button type="button" onClick={() => { if (selected === 1) openVoice(); else { if (selected === 0) setMode('Compose'); setAction('voice'); } }}>Voice</button>{selected === 1 ? <button type="button" onClick={openCompose}>Compose</button> : <button type="button" onClick={() => { if (selected === 0) setMode('Compose'); setAction('photo'); }}>Photo</button>}<button type="button" onClick={() => { setAction(null); setKeyboardActive(false); keyboardRef.current?.blur(); }}>Reset preview</button></div>
          </div>

          <div className={styles.explanation}>
            <p className={styles.eyebrow}>HOW IT WORKS</p>
            <h3>{active.summary}</h3>
            <div className={styles.flow}><div><span>MICROPHONE</span><p>{active.voice}</p></div><div><span>PHOTO</span><p>{active.photo}</p></div></div>
            <div className={styles.tradeoffs}><div><h4>Pros</h4><ul>{active.pros.map((item) => <li key={item}>{item}</li>)}</ul></div><div><h4>Cons</h4><ul>{active.cons.map((item) => <li key={item}>{item}</li>)}</ul></div></div>
            {selected === 1 && <div className={styles.recommendation}><strong>One-row proposal</strong><p>Keyboard opens Compose directly; tapping terminal output opens Live typing. Voice swaps the toolbar for a recording bar with one checkmark button, then opens the same Compose bubble. Photo sits outside on the left, while the draft and Voice sit inside. Send appears only when the draft contains text.</p></div>}
          </div>
        </section>
        <footer className={styles.footer}>These are UI proposals. Buttons in the sketch demonstrate the flow and do not send anything to a pane.</footer>
      </div>
    </main>
  );
}
