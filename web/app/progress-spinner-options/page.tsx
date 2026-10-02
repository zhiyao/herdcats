'use client';

import { useState } from 'react';
import styles from './page.module.css';

type Direction = 'native' | 'tokens' | 'adaptive';

const directions: {
  id: Direction;
  number: string;
  name: string;
  summary: string;
  badge: string;
  features: string[];
  codeHint: string;
}[] = [
  {
    id: 'native',
    number: '01',
    name: 'Strict Native Scale',
    summary: 'Standardize directly on Apple SwiftUI .controlSize (.mini, .small, .regular) and remove all custom geometric spinner loops.',
    badge: 'Minimal Surface',
    features: [
      'Eliminates hand-rolled Circle().trim in Live keyboard; replaces with ProgressView().controlSize(.mini).tint(Theme.accent)',
      'Locks all action buttons (Connect, Send, Mark As Read, Refresh) to .controlSize(.small)',
      'Standardizes tags, chips, and pending indicators to .controlSize(.mini)',
      'Automatic system accessibilityReduceMotion compliance across all elements',
    ],
    codeHint: 'ProgressView().controlSize(.small)',
  },
  {
    id: 'tokens',
    number: '02',
    name: 'Unified Token Primitives',
    summary: 'Introduce a centralized HerdrSpinner and .herdrButtonLoading() modifier in DesignSystem.swift to prevent layout jumps.',
    badge: 'Design System',
    features: [
      'Button loading modifier maintains exact frame so spinner swaps never jank layout',
      'Centralized HerdrSpinner(size: .button, tint: .white) in Components.swift',
      'Unified HerdrLoadingState(message:) replaces ad-hoc ProgressView + text stacks',
      'Single source of truth for accessibility labels and reduced-motion fallbacks',
    ],
    codeHint: 'Button("Connect").herdrButtonLoading(isConnecting)',
  },
  {
    id: 'adaptive',
    number: '03',
    name: 'Context-Adaptive Tiering',
    summary: 'Differentiate spinners by semantic domain to maximize instant peripheral awareness.',
    badge: 'Brand & Terminal',
    features: [
      'LazyCatLoadingView reserved exclusively for remote host SSH handshakes',
      'WorkingStatusIcon (amber rotating circular arrow) reserved strictly for AgentStatus.working',
      'Turquoise terminal indicator for active Live keyboard keystrokes and PTY draining',
      'Clean monochrome ProgressView for local phone UI interactions',
      'Determinate QuotaRing for capacity percentages and burn pace',
    ],
    codeHint: 'Semantic color & archetype mapping',
  },
];

function NativeIosSpinner({ size = 'small', color = 'currentColor' }: { size?: 'mini' | 'small'; color?: string }) {
  const isMini = size === 'mini';
  return (
    <span
      className={`${styles.spinnerIos} ${isMini ? styles.spinnerIosMini : ''}`}
      style={{ color }}
      aria-hidden="true"
    >
      {Array.from({ length: 12 }).map((_, i) => (
        <span key={i} className={styles.spinnerBlade} />
      ))}
    </span>
  );
}

export default function ProgressSpinnerOptionsPage() {
  const [selectedDirection, setSelectedDirection] = useState<Direction>('tokens');
  const [isSimulating, setIsSimulating] = useState(true);
  const [quotaVal, setQuotaVal] = useState(72);

  const selected = directions.find((d) => d.id === selectedDirection) ?? directions[1];

  return (
    <div className={styles.page}>
      <header className={styles.header}>
        <div className={styles.eyebrow}>Herdcats · Design System Suite</div>
        <h1 className={styles.title}>Progress & Spinner Consolidation</h1>
        <p className={styles.lead}>
          Herdcats currently contains 16 distinct progress views, hand-rolled circular stroke loops, rotating SF Symbols,
          and pixel cat animations with inconsistent sizing and tints. Below are 3 strategic architectural directions to unify them.
        </p>
      </header>

      {/* Direction Cards */}
      <section className={styles.directionsGrid} aria-label="Consolidation options">
        {directions.map((d) => (
          <div
            key={d.id}
            className={`${styles.directionCard} ${selectedDirection === d.id ? styles.selectedCard : ''}`}
            onClick={() => setSelectedDirection(d.id)}
            role="button"
            tabIndex={0}
            onKeyDown={(e) => e.key === 'Enter' && setSelectedDirection(d.id)}
          >
            <div className={styles.cardTop}>
              <span className={styles.cardNumber}>Option {d.number}</span>
              <span className={styles.badge}>{d.badge}</span>
            </div>
            <h2 className={styles.directionTitle}>{d.name}</h2>
            <p className={styles.directionSummary}>{d.summary}</p>
            <ul className={styles.featureList}>
              {d.features.map((feat, idx) => (
                <li key={idx} className={styles.featureItem}>
                  <span className={styles.featureCheck}>✓</span>
                  <span>{feat}</span>
                </li>
              ))}
            </ul>
          </div>
        ))}
      </section>

      {/* Interactive Preview Sandbox */}
      <section className={styles.previewSection}>
        <div className={styles.previewHeader}>
          <div className={styles.previewTitle}>
            <h3>Live Behavior under {selected.name}</h3>
            <p>Interactive preview of consolidated component tokens across primary actions.</p>
          </div>
          <button
            type="button"
            className={styles.buttonMock}
            style={{ height: 36, fontSize: 12, padding: '0 14px' }}
            onClick={() => setIsSimulating(!isSimulating)}
          >
            {isSimulating ? '⏸ Pause Loading States' : '▶️ Trigger Loading States'}
          </button>
        </div>

        <div className={styles.previewGrid}>
          {/* Primary Action Button */}
          <div className={styles.compBox}>
            <div className={styles.compName}>Primary Action (ConnectView)</div>
            <div className={styles.compContent}>
              <button type="button" className={styles.buttonMock}>
                {isSimulating ? (
                  <>
                    <NativeIosSpinner size="small" color="#003e43" />
                    Connecting…
                  </>
                ) : (
                  'Connect'
                )}
              </button>
            </div>
            <div className={styles.compFootnote}>
              Token: <code>.controlSize(.small)</code> · Balanced with 14pt bold typography.
            </div>
          </div>

          {/* Floating Mark as Read */}
          <div className={styles.compBox}>
            <div className={styles.compName}>Floating Action Button (SpaceDetailView)</div>
            <div className={styles.compContent}>
              <div className={styles.fabMock}>
                {isSimulating ? <NativeIosSpinner size="small" color="#ffffff" /> : '✓'}
              </div>
            </div>
            <div className={styles.compFootnote}>
              Token: <code>.controlSize(.small)</code> in 44pt circular action button.
            </div>
          </div>

          {/* Live Keyboard Status */}
          <div className={styles.compBox}>
            <div className={styles.compName}>Live Terminal Activity (SpaceDetailView)</div>
            <div className={styles.compContent}>
              <div className={styles.liveMock}>
                <span>Live Keystrokes</span>
                {isSimulating && (
                  <NativeIosSpinner size="mini" color="var(--color-primary, #0edcd5)" />
                )}
              </div>
            </div>
            <div className={styles.compFootnote}>
              Token: <code>.controlSize(.mini)</code> · Replaces custom stroke arc loop.
            </div>
          </div>

          {/* Agent Status Icon */}
          <div className={styles.compBox}>
            <div className={styles.compName}>Agent Status (WorkingStatusIcon)</div>
            <div className={styles.compContent}>
              <div style={{ display: 'flex', alignItems: 'center', gap: 8, fontSize: 13, fontWeight: 600 }}>
                <svg className={styles.workingSpinner} viewBox="0 0 24 24">
                  <circle cx="12" cy="12" r="9" fill="none" stroke="var(--color-status-working, #ffd60a)" strokeWidth="2.5" strokeDasharray="45 15" strokeLinecap="round" />
                </svg>
                <span style={{ color: 'var(--color-status-working, #ffd60a)' }}>Working</span>
              </div>
            </div>
            <div className={styles.compFootnote}>
              Unified with <code>CircularArcSpinner</code> in yellow at 14pt.
            </div>
          </div>
        </div>
      </section>

      {/* Quota Determinate Metric Section */}
      <section className={styles.previewSection}>
        <div className={styles.previewHeader}>
          <div className={styles.previewTitle}>
            <h3>Determinate Progress: Quota Rings</h3>
            <p>Calculated percentage burn-down meters remain separate from indeterminate activity spinners.</p>
          </div>
          <div style={{ display: 'flex', alignItems: 'center', gap: 10 }}>
            <span style={{ fontSize: 13, color: 'var(--color-on-surface-secondary, #8e8e93)' }}>Remaining:</span>
            <input
              type="range"
              min={0}
              max={100}
              value={quotaVal}
              onChange={(e) => setQuotaVal(Number(e.target.value))}
              style={{ accentColor: 'var(--color-primary, #0edcd5)' }}
            />
            <strong style={{ fontSize: 14, minWidth: 40 }}>{quotaVal}%</strong>
          </div>
        </div>

        <div style={{ display: 'flex', alignItems: 'center', gap: 24, flexWrap: 'wrap' }}>
          <svg style={{ width: 68, height: 68, transform: 'rotate(-90deg)' }} viewBox="0 0 40 40">
            <circle cx="20" cy="20" r="16" fill="none" stroke="rgba(255,255,255,0.12)" strokeWidth="4" />
            <circle
              cx="20"
              cy="20"
              r="16"
              fill="none"
              stroke={quotaVal < 20 ? 'var(--color-error, #ff453a)' : quotaVal < 50 ? 'var(--color-status-working, #ffd60a)' : 'var(--color-primary, #0edcd5)'}
              strokeWidth="4"
              strokeLinecap="round"
              strokeDasharray={100.5}
              strokeDashoffset={100.5 - (quotaVal / 100) * 100.5}
              style={{ transition: 'stroke-dashoffset 0.3s ease, stroke 0.3s ease' }}
            />
          </svg>
          <div style={{ maxWidth: 640 }}>
            <p style={{ fontSize: 13, color: 'var(--color-on-surface-secondary, #8e8e93)', lineHeight: 1.5 }}>
              In <code>QuotaScreen.swift</code>, progress rings indicate quota exhaustion rather than system wait states.
              Keeping this distinction crisp avoids visual ambiguity between "the phone is waiting on a server" and "the remote machine has consumed capacity".
            </p>
          </div>
        </div>
      </section>

      {/* Implementation Spec */}
      <section className={styles.previewSection}>
        <div className={styles.previewTitle} style={{ marginBottom: 16 }}>
          <h3>Swift Architecture Blueprint ({selected.name})</h3>
          <p>Recommended implementation snippet for <code>ios/Herdcats/Features/DesignSystem.swift</code>.</p>
        </div>
        <pre className={styles.codeBox}>
          <code>{selected.id === 'native' ? `// Option 01: Standardized Native Sizing Rules
// Standardize on 3 canonical SwiftUI controlSize levels:
// 1. .mini    -> Attachment chips, pending tabs, status bar
// 2. .small   -> Action buttons (Connect, Send, Mark Seen, Refresh)
// 3. .regular -> Full-sheet modal loaders

ProgressView()
    .controlSize(.small)
    .tint(.white)` : selected.id === 'tokens' ? `// Option 02: DesignSystem.swift Unified Primitives
enum HerdrSpinnerSize {
    case mini    // 12pt (chips, tags, status bar)
    case button  // 16pt (all action buttons)
    case regular // 22pt (view/modal loaders)
}

struct HerdrSpinner: View {
    var size: HerdrSpinnerSize = .button
    var tint: Color? = nil
    var body: some View {
        ProgressView()
            .controlSize(size == .mini ? .mini : size == .button ? .small : .regular)
            .tint(tint)
    }
}

// Prevents layout jumping when buttons enter loading state:
extension View {
    func herdrButtonLoading(isBusy: Bool, tint: Color = .white) -> some View {
        overlay {
            if isBusy { HerdrSpinner(size: .button, tint: tint) }
        }
        .opacity(isBusy ? 0 : 1)
        .disabled(isBusy)
    }
}` : `// Option 03: Context-Adaptive Visual Identity
// 1. SSH Host Handshake -> LazyCatLoadingView (Tabby pixel sprite)
// 2. Agent Execution   -> WorkingStatusIcon (SF Symbol rotating at 30 fps)
// 3. Terminal Live Keystrokes -> Mini Turquoise Activity Spinner
// 4. Local User Actions -> Monochrome Apple ProgressView`}</code>
        </pre>
      </section>
    </div>
  );
}
