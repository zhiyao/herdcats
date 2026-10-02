'use client';

import React, { useState, useRef, useEffect } from 'react';
import Link from 'next/link';
import Image from 'next/image';

type DesignOption = 'option1' | 'option2' | 'option3' | 'gallery';
type AgentKind = 'claude' | 'codex' | 'cursor' | 'gemini' | 'default';

interface CommandItem {
  id: string;
  title: string;
  keys: string;
  category: 'chord' | 'slash' | 'git' | 'custom';
  color?: string;
  icon?: string;
}

const AGENT_DATA: Record<AgentKind, { name: string; color: string; commands: CommandItem[] }> = {
  claude: {
    name: 'Claude Code',
    color: '#D97857',
    commands: [
      { id: 'c-tab', title: 'Accept Tab', keys: '⇥', category: 'chord' },
      { id: 'c-shift-tab', title: 'Back Tab', keys: '⇧⇥', category: 'chord' },
      { id: 'c-ctrl-c', title: 'Interrupt', keys: '⌃C', category: 'chord', color: '#FF453A' },
      { id: 'c-alt-up', title: 'Prev Message', keys: '⌥↑', category: 'chord' },
      { id: 'c-alt-down', title: 'Next Message', keys: '⌥↓', category: 'chord' },
      { id: 'c-compact', title: 'Compact Context', keys: '/compact', category: 'slash' },
      { id: 'c-review', title: 'Review Code', keys: '/review', category: 'slash' },
      { id: 'c-cost', title: 'Token Cost', keys: '/cost', category: 'slash' },
      { id: 'c-clear', title: 'Clear History', keys: '/clear', category: 'slash', color: '#FF9F0A' },
      { id: 'c-diff', title: 'Git Diff', keys: 'git diff', category: 'git' },
      { id: 'c-status', title: 'Git Status', keys: 'git status', category: 'git' },
      { id: 'c-commit', title: 'Auto Commit', keys: 'git commit -m', category: 'git' },
    ],
  },
  codex: {
    name: 'OpenAI Codex',
    color: '#17A382',
    commands: [
      { id: 'cx-tab', title: 'Accept Next', keys: '⇥', category: 'chord' },
      { id: 'cx-shift-tab', title: 'Cycle Prev', keys: '⇧⇥', category: 'chord' },
      { id: 'cx-alt-down', title: 'Next Suggestion', keys: '⌥↓', category: 'chord' },
      { id: 'cx-alt-up', title: 'Prev Suggestion', keys: '⌥↑', category: 'chord' },
      { id: 'cx-ctrl-bracket', title: 'Inspect Diff', keys: '⌃]', category: 'chord' },
      { id: 'cx-explain', title: 'Explain Logic', keys: '/explain', category: 'slash' },
      { id: 'cx-test', title: 'Generate Tests', keys: '/test', category: 'slash' },
      { id: 'cx-fix', title: 'Fix Diagnostic', keys: '/fix', category: 'slash' },
      { id: 'cx-diff', title: 'Git Diff', keys: 'git diff', category: 'git' },
      { id: 'cx-revert', title: 'Revert Chunk', keys: 'git checkout -p', category: 'git' },
    ],
  },
  cursor: {
    name: 'Cursor Agent',
    color: '#8CBDFA',
    commands: [
      { id: 'cu-tab', title: 'Accept Partial', keys: '⇥', category: 'chord' },
      { id: 'cu-cmd-k', title: 'Inline Edit', keys: '⌘K', category: 'chord' },
      { id: 'cu-cmd-i', title: 'Composer Pane', keys: '⌘I', category: 'chord' },
      { id: 'cu-shift-tab', title: 'Next Match', keys: '⇧⇥', category: 'chord' },
      { id: 'cu-plan', title: 'Generate Plan', keys: '/plan', category: 'slash' },
      { id: 'cu-search', title: 'Codebase Search', keys: '/search', category: 'slash' },
      { id: 'cu-symbols', title: 'Symbol Lookup', keys: '@symbols', category: 'slash' },
      { id: 'cu-stash', title: 'Git Stash', keys: 'git stash', category: 'git' },
    ],
  },
  gemini: {
    name: 'Gemini / Agy',
    color: '#8F76B2',
    commands: [
      { id: 'g-tab', title: 'Accept Chunk', keys: '⇥', category: 'chord' },
      { id: 'g-shift-tab', title: 'Prev Chunk', keys: '⇧⇥', category: 'chord' },
      { id: 'g-ctrl-space', title: 'Prompt Autocomplete', keys: '⌃␣', category: 'chord' },
      { id: 'g-esc', title: 'Halt Agent', keys: '⎋', category: 'chord', color: '#FF453A' },
      { id: 'g-multimodal', title: 'Analyze Screen', keys: '/image', category: 'slash' },
      { id: 'g-refactor', title: 'Full Refactor', keys: '/refactor', category: 'slash' },
      { id: 'g-bench', title: 'Run Benchmark', keys: '/bench', category: 'slash' },
      { id: 'g-branch', title: 'Switch Worktree', keys: 'git checkout', category: 'git' },
    ],
  },
  default: {
    name: 'Standard Shell',
    color: '#0EDCD5',
    commands: [
      { id: 'd-tab', title: 'Tab Complete', keys: '⇥', category: 'chord' },
      { id: 'd-shift-tab', title: 'Reverse Tab', keys: '⇧⇥', category: 'chord' },
      { id: 'd-ctrl-c', title: 'SIGINT Kill', keys: '⌃C', category: 'chord', color: '#FF453A' },
      { id: 'd-ctrl-l', title: 'Clear Screen', keys: '⌃L', category: 'chord' },
      { id: 'd-ctrl-r', title: 'Reverse Search', keys: '⌃R', category: 'chord' },
      { id: 'd-ctrl-z', title: 'Suspend Task', keys: '⌃Z', category: 'chord' },
      { id: 'd-git-status', title: 'Repo Status', keys: 'git status', category: 'git' },
      { id: 'd-git-log', title: 'Commit Log', keys: 'git log --oneline -n 5', category: 'git' },
    ],
  },
};

export default function CommandPanePrototypePage() {
  const [option, setOption] = useState<DesignOption>('option1');
  const [agent, setAgent] = useState<AgentKind>('claude');
  const [isExpanded, setIsExpanded] = useState(true);
  const [filterCategory, setFilterCategory] = useState<'all' | 'chord' | 'slash' | 'git'>('all');
  const [activeTabOption3, setActiveTabOption3] = useState<'chord' | 'slash' | 'git' | 'custom'>('chord');
  const [customCommands, setCustomCommands] = useState<CommandItem[]>([
    { id: 'cust-1', title: 'Run Linter', keys: 'npm run lint', category: 'custom' },
    { id: 'cust-2', title: 'Build Project', keys: 'npm run build', category: 'custom' },
  ]);
  const [newKeyInput, setNewKeyInput] = useState('');
  const [newTitleInput, setNewTitleInput] = useState('');
  const [showAddModal, setShowAddModal] = useState(false);

  // Terminal log state
  const [terminalLines, setTerminalLines] = useState<string[]>([
    'Herdr SSH session connected: remote-mac.tailscale:22',
    '[space: #3 · auth-service · 2 panes · Claude Code]',
    '[agent: claude-code v1.2.8 — status: WORKING]',
    'claude> Searching repository for authorization headers...',
    'claude> Modified src/auth/token_verifier.ts (+14, -3)',
    'claude> Waiting for approval or command chord...',
  ]);

  const terminalEndRef = useRef<HTMLDivElement>(null);

  const scrollToBottom = () => {
    terminalEndRef.current?.scrollIntoView({ behavior: 'smooth' });
  };

  useEffect(() => {
    scrollToBottom();
  }, [terminalLines]);

  const sendTerminalAction = (label: string, value: string, isStandardKey = false) => {
    const timestamp = new Date().toLocaleTimeString('en-US', { hour12: false });
    let logMessage = '';
    if (isStandardKey) {
      logMessage = `\u001b[36m[${timestamp}] [STANDARD KEY] Pressed: "${label}" (${value})\u001b[0m`;
    } else {
      logMessage = `[${timestamp}] Sent to agent: "${label}" [${value}]`;
    }

    if (value === 'escape' || value === 'ctrl+c') {
      logMessage = `\u001b[31m[${timestamp}] [SIGINT / INTERRUPT] Stopped agent loop via ${label}\u001b[0m`;
    } else if (value === 'clear') {
      setTerminalLines(['Terminal cleared by Herdcats command.']);
      return;
    }

    setTerminalLines((prev) => [...prev, logMessage]);
  };

  const currentAgent = AGENT_DATA[agent];
  const allCommands = [...currentAgent.commands, ...customCommands];
  const filteredCommands =
    filterCategory === 'all'
      ? allCommands
      : allCommands.filter((c) => c.category === filterCategory);

  const addCustomShortcut = () => {
    if (!newKeyInput.trim()) return;
    const newItem: CommandItem = {
      id: `custom-${Date.now()}`,
      title: newTitleInput.trim() || newKeyInput.trim(),
      keys: newKeyInput.trim(),
      category: 'custom',
    };
    setCustomCommands((prev) => [...prev, newItem]);
    setNewKeyInput('');
    setNewTitleInput('');
    setShowAddModal(false);
    sendTerminalAction(`Added Custom Macro: ${newItem.title}`, newItem.keys);
  };

  return (
    <div className="prototype-wrapper">
      {/* Top Header & Navigation */}
      <header className="proto-header">
        <div className="proto-header-left">
          <Link href="/" className="proto-back-btn">
            ← Back to Home
          </Link>
          <div className="proto-titles">
            <h1>Command Pane Redesign Simulator</h1>
            <p>Interactive web execution comparing 3 architectural layouts before iOS rollout</p>
          </div>
        </div>

        {/* Global Agent Switcher */}
        <div className="agent-switcher-bar">
          <span className="agent-label">Simulate Agent:</span>
          {(Object.keys(AGENT_DATA) as AgentKind[]).map((k) => (
            <button
              key={k}
              type="button"
              className={`agent-tab-btn ${agent === k ? 'active' : ''}`}
              style={{
                borderColor: agent === k ? AGENT_DATA[k].color : 'transparent',
                color: agent === k ? AGENT_DATA[k].color : '#8E8E93',
              }}
              onClick={() => {
                setAgent(k);
                setTerminalLines((prev) => [
                  ...prev,
                  `[Switched active pane agent to: ${AGENT_DATA[k].name}]`,
                ]);
              }}
            >
              <span
                className="agent-dot"
                style={{ backgroundColor: AGENT_DATA[k].color }}
              />
              {AGENT_DATA[k].name}
            </button>
          ))}
        </div>
      </header>

      {/* Main Switcher Controls */}
      <div className="proto-nav-pills">
        <button
          type="button"
          className={`pill-btn ${option === 'option1' ? 'active' : ''}`}
          onClick={() => setOption('option1')}
        >
          <span className="pill-num">1</span>
          Option 1: The Split Console
          <span className="pill-badge">Anchored Dock + 3-Col Grid</span>
        </button>
        <button
          type="button"
          className={`pill-btn ${option === 'option2' ? 'active' : ''}`}
          onClick={() => setOption('option2')}
        >
          <span className="pill-num">2</span>
          Option 2: The Command Deck
          <span className="pill-badge">Dual-Zone D-Pad + Macro Deck</span>
        </button>
        <button
          type="button"
          className={`pill-btn ${option === 'option3' ? 'active' : ''}`}
          onClick={() => setOption('option3')}
        >
          <span className="pill-num">3</span>
          Option 3: The Sheet Controller
          <span className="pill-badge">Segmented Tabs + Standard Dock</span>
        </button>
        <button
          type="button"
          className={`pill-btn ${option === 'gallery' ? 'active' : ''}`}
          onClick={() => setOption('gallery')}
        >
          <span className="pill-num">✦</span>
          Visual Mockups & Comparison
          <span className="pill-badge">Generated UI Mockups</span>
        </button>
      </div>

      {/* Content Area: Interactive Phone Frame + Design Architecture Sidebar */}
      <div className="proto-body-grid">
        {option === 'gallery' ? (
          /* Gallery Mode */
          <div className="gallery-full-container">
            <div className="gallery-header">
              <h2>Visual Design Mockups (High-Resolution Renders)</h2>
              <p>
                Generated high-fidelity UI specifications depicting how the expanded command grid
                transforms the mobile developer experience.
              </p>
            </div>

            <div className="gallery-grid">
              {/* Card 1 */}
              <div className="gallery-card">
                <div className="gallery-img-container">
                  <Image
                    src="/assets/prototypes/command_grid_anchored_1790167210772.jpg"
                    alt="Option 1: The Split Console"
                    width={420}
                    height={840}
                    className="gallery-img"
                    unoptimized
                  />
                </div>
                <div className="gallery-info">
                  <div className="gallery-tag option1-tag">Option 1: The Split Console</div>
                  <h3>Anchored Utility Dock + 3-Column Scroll Grid</h3>
                  <p>
                    <strong>Ergonomics:</strong> Anchors muscle-memory keys (Esc, Tab, Arrow keys, Return)
                    at the very bottom touch edge. Above it, a spacious 3-column scrollable grid displays
                    high-density agent chords and slash actions with category filtering.
                  </p>
                  <ul>
                    <li>✓ Zero reach strain for Esc & Return</li>
                    <li>✓ 3-column grid gives 12+ visible chips without cramping</li>
                    <li>✓ Category pills let users jump between Chords and Slash</li>
                  </ul>
                  <button
                    type="button"
                    className="try-in-sim-btn"
                    onClick={() => setOption('option1')}
                  >
                    Try Option 1 in Live Simulator →
                  </button>
                </div>
              </div>

              {/* Card 2 */}
              <div className="gallery-card">
                <div className="gallery-img-container">
                  <Image
                    src="/assets/prototypes/command_deck_dualzone_1790167229551.jpg"
                    alt="Option 2: The Command Deck"
                    width={420}
                    height={840}
                    className="gallery-img"
                    unoptimized
                  />
                </div>
                <div className="gallery-info">
                  <div className="gallery-tag option2-tag">Option 2: The Command Deck</div>
                  <h3>Dual-Zone Matrix (Left D-Pad + Right Action Deck)</h3>
                  <p>
                    <strong>Ergonomics:</strong> Inspired by handheld console controllers and macro pads.
                    The left 38% width is a permanent physical-style D-pad with Esc and Enter. The right 62%
                    is a 2-column scrollable deck with rich action tiles and empty customizable &quot;+&quot; slots.
                  </p>
                  <ul>
                    <li>✓ Perfect for rapid two-thumb or left-thumb navigation</li>
                    <li>✓ Dedicated directional pad for CLI menus and command history</li>
                    <li>✓ Distinct tactile identity for autonomous agent macro keys</li>
                  </ul>
                  <button
                    type="button"
                    className="try-in-sim-btn"
                    onClick={() => setOption('option2')}
                  >
                    Try Option 2 in Live Simulator →
                  </button>
                </div>
              </div>

              {/* Card 3 */}
              <div className="gallery-card">
                <div className="gallery-img-container">
                  <Image
                    src="/assets/prototypes/command_sheet_tabbed_1790167255868.jpg"
                    alt="Option 3: The Sheet Controller"
                    width={420}
                    height={840}
                    className="gallery-img"
                    unoptimized
                  />
                </div>
                <div className="gallery-info">
                  <div className="gallery-tag option3-tag">Option 3: The Sheet Controller</div>
                  <h3>Expandable Modal Drawer + Segmented Category Tabs</h3>
                  <p>
                    <strong>Ergonomics:</strong> Standard iOS 17 bottom drawer pattern. Slides up smoothly with
                    a drag handle. Has swipeable/clickable segmented category tabs (Agent Chords, Slash Commands,
                    Git, Custom) with a spacious 3x4 grid and anchored 5-key bottom rail.
                  </p>
                  <ul>
                    <li>✓ Clean categorization prevents visual clutter</li>
                    <li>✓ Native iOS drag gesture feels standard and intuitive</li>
                    <li>✓ Accommodates 30+ shortcuts without cognitive overload</li>
                  </ul>
                  <button
                    type="button"
                    className="try-in-sim-btn"
                    onClick={() => setOption('option3')}
                  >
                    Try Option 3 in Live Simulator →
                  </button>
                </div>
              </div>
            </div>
          </div>
        ) : (
          /* Live Interactive Phone Frame Simulator */
          <>
            <div className="phone-simulator-column">
              <div className="phone-device-frame">
                {/* Dynamic Island / Notch */}
                <div className="phone-island">
                  <div className="island-camera" />
                </div>

                {/* iPhone Status Bar */}
                <div className="phone-status-bar">
                  <span>9:41</span>
                  <div className="phone-status-icons">
                    <span>5G</span>
                    <span>100%</span>
                  </div>
                </div>

                {/* Herdr Navigation Header */}
                <div className="phone-nav-header">
                  <div className="phone-nav-left">
                    <span className="space-pill">#3 auth-service</span>
                    <span
                      className="agent-status-badge"
                      style={{
                        backgroundColor: `${currentAgent.color}22`,
                        color: currentAgent.color,
                        borderColor: currentAgent.color,
                      }}
                    >
                      ● {currentAgent.name}
                    </span>
                  </div>
                  <button
                    type="button"
                    className="pane-toggle-btn"
                    title="Toggle Expand / Collapse"
                    onClick={() => setIsExpanded(!isExpanded)}
                  >
                    {isExpanded ? 'Collapse ▾' : 'Expand ▴'}
                  </button>
                </div>

                {/* Monospace Terminal Output Window */}
                <div className="terminal-viewport">
                  <div className="terminal-lines">
                    {terminalLines.map((line, idx) => (
                      <div
                        key={idx}
                        className={`terminal-line ${
                          line.includes('SIGINT')
                            ? 'line-danger'
                            : line.includes('STANDARD')
                            ? 'line-cyan'
                            : line.includes('claude>')
                            ? 'line-agent'
                            : ''
                        }`}
                      >
                        {line}
                      </div>
                    ))}
                    <div ref={terminalEndRef} />
                  </div>
                </div>

                {/* EXPANDED COMMAND PANE CONTAINER */}
                {isExpanded ? (
                  <div className="expanded-command-pane">
                    {/* OPTION 1: THE SPLIT CONSOLE */}
                    {option === 'option1' && (
                      <div className="option1-view">
                        <div className="pane-grabber-bar" onClick={() => setIsExpanded(false)} style={{ cursor: 'pointer' }}>
                          <span className="grabber" />
                          <div className="pane-header-title">
                            <div style={{ display: 'flex', alignItems: 'center', gap: 6 }}>
                              <span>Command Pad</span>
                              <span
                                className="agent-indicator"
                                style={{
                                  color: currentAgent.color,
                                  backgroundColor: `${currentAgent.color}25`
                                }}
                              >
                                {agent === 'claude' ? '⌥' : agent === 'codex' ? '✦' : '◆'} {currentAgent.name}
                              </span>
                            </div>
                            <button
                              type="button"
                              className="dismiss-chevron-btn"
                              title="Dismiss Command Pad"
                              onClick={(e) => {
                                e.stopPropagation();
                                setIsExpanded(false);
                              }}
                            >
                              ▾
                            </button>
                          </div>
                        </div>

                        {/* Filter Categories */}
                        <div className="category-filter-strip">
                          {(['all', 'chord', 'slash', 'git'] as const).map((cat) => (
                            <button
                              key={cat}
                              type="button"
                              className={`filter-chip ${filterCategory === cat ? 'active' : ''}`}
                              onClick={() => setFilterCategory(cat)}
                            >
                              {cat === 'all'
                                ? 'All'
                                : cat === 'chord'
                                ? 'Chords'
                                : cat === 'slash'
                                ? 'Slash /'
                                : 'Git'}
                            </button>
                          ))}
                          <button
                            type="button"
                            className="filter-chip add-chip"
                            onClick={() => setShowAddModal(true)}
                          >
                            + Custom
                          </button>
                        </div>

                        {/* Scrollable 3-Column Grid */}
                        <div className="scrollable-command-grid grid-3col">
                          {filteredCommands.map((cmd) => (
                            <button
                              key={cmd.id}
                              type="button"
                              className="command-card"
                              onClick={() => sendTerminalAction(cmd.title, cmd.keys)}
                            >
                              <span className="cmd-keys" style={{ color: cmd.color || '#0EDCD5' }}>
                                {cmd.keys}
                              </span>
                              <span className="cmd-title">{cmd.title}</span>
                            </button>
                          ))}
                        </div>

                        {/* Standardized Bottom Dock */}
                        <div className="standardized-dock">
                          <button
                            type="button"
                            className="std-key key-esc"
                            onClick={() => sendTerminalAction('Esc (Stop)', 'escape', true)}
                          >
                            Esc
                          </button>
                          <button
                            type="button"
                            className="std-key"
                            onClick={() => sendTerminalAction('Tab', 'tab', true)}
                          >
                            Tab
                          </button>
                          <button
                            type="button"
                            className="std-key"
                            onClick={() => sendTerminalAction('⇧Tab', 'shift+tab', true)}
                          >
                            ⇧Tab
                          </button>
                          <button
                            type="button"
                            className="std-key"
                            onClick={() => sendTerminalAction('Left', 'left', true)}
                          >
                            ←
                          </button>
                          <button
                            type="button"
                            className="std-key"
                            onClick={() => sendTerminalAction('Up (History)', 'up', true)}
                          >
                            ↑
                          </button>
                          <button
                            type="button"
                            className="std-key"
                            onClick={() => sendTerminalAction('Down (History)', 'down', true)}
                          >
                            ↓
                          </button>
                          <button
                            type="button"
                            className="std-key"
                            onClick={() => sendTerminalAction('Right', 'right', true)}
                          >
                            →
                          </button>
                          <button
                            type="button"
                            className="std-key key-return"
                            onClick={() => sendTerminalAction('Return', 'enter', true)}
                          >
                            ⏎
                          </button>
                        </div>
                      </div>
                    )}

                    {/* OPTION 2: THE COMMAND DECK */}
                    {option === 'option2' && (
                      <div className="option2-view">
                        <div className="pane-grabber-bar">
                          <span className="grabber" />
                          <div className="pane-header-title">
                            <span>Virtual Controller Deck</span>
                            <button
                              type="button"
                              className="quick-add-btn"
                              onClick={() => setShowAddModal(true)}
                            >
                              + Add Slot
                            </button>
                          </div>
                        </div>

                        <div className="dual-zone-container">
                          {/* Left Column: Standardized Controller Thumb Cluster */}
                          <div className="left-thumb-zone">
                            <div className="dpad-top-row">
                              <button
                                type="button"
                                className="std-key key-esc"
                                onClick={() => sendTerminalAction('Esc', 'escape', true)}
                              >
                                Esc
                              </button>
                              <button
                                type="button"
                                className="std-key"
                                onClick={() => sendTerminalAction('Ctrl+C', 'ctrl+c', true)}
                              >
                                ⌃C
                              </button>
                            </div>
                            <div className="dpad-top-row">
                              <button
                                type="button"
                                className="std-key"
                                onClick={() => sendTerminalAction('Tab', 'tab', true)}
                              >
                                Tab
                              </button>
                              <button
                                type="button"
                                className="std-key key-return"
                                onClick={() => sendTerminalAction('Enter', 'enter', true)}
                              >
                                ⏎
                              </button>
                            </div>

                            {/* Tactile Cross D-Pad */}
                            <div className="cross-dpad">
                              <button
                                type="button"
                                className="dpad-btn dpad-up"
                                onClick={() => sendTerminalAction('D-Pad Up', 'up', true)}
                              >
                                ▲
                              </button>
                              <div className="dpad-mid-row">
                                <button
                                  type="button"
                                  className="dpad-btn dpad-left"
                                  onClick={() => sendTerminalAction('D-Pad Left', 'left', true)}
                                >
                                  ◀
                                </button>
                                <button
                                  type="button"
                                  className="dpad-btn dpad-center"
                                  onClick={() => sendTerminalAction('Center Execute', 'enter', true)}
                                >
                                  OK
                                </button>
                                <button
                                  type="button"
                                  className="dpad-btn dpad-right"
                                  onClick={() => sendTerminalAction('D-Pad Right', 'right', true)}
                                >
                                  ▶
                                </button>
                              </div>
                              <button
                                type="button"
                                className="dpad-btn dpad-down"
                                onClick={() => sendTerminalAction('D-Pad Down', 'down', true)}
                              >
                                ▼
                              </button>
                            </div>
                          </div>

                          {/* Right Zone: 2-Column Scrollable Action Deck */}
                          <div className="right-action-deck">
                            <div className="scrollable-deck-grid">
                              {allCommands.map((cmd) => (
                                <button
                                  key={cmd.id}
                                  type="button"
                                  className="deck-card"
                                  onClick={() => sendTerminalAction(cmd.title, cmd.keys)}
                                >
                                  <div className="deck-card-top">
                                    <span className="deck-tag">{cmd.category}</span>
                                    <span className="deck-chord">{cmd.keys}</span>
                                  </div>
                                  <div className="deck-card-title">{cmd.title}</div>
                                </button>
                              ))}
                              <button
                                type="button"
                                className="deck-card deck-add-card"
                                onClick={() => setShowAddModal(true)}
                              >
                                <span className="add-icon">+</span>
                                <span>Custom Slot</span>
                              </button>
                            </div>
                          </div>
                        </div>
                      </div>
                    )}

                    {/* OPTION 3: THE SHEET CONTROLLER */}
                    {option === 'option3' && (
                      <div className="option3-view">
                        <div className="pane-grabber-bar">
                          <span className="grabber" />
                        </div>

                        {/* Segmented Category Tabs */}
                        <div className="segmented-tab-row">
                          <button
                            type="button"
                            className={`seg-tab ${activeTabOption3 === 'chord' ? 'active' : ''}`}
                            onClick={() => setActiveTabOption3('chord')}
                          >
                            Agent Chords
                          </button>
                          <button
                            type="button"
                            className={`seg-tab ${activeTabOption3 === 'slash' ? 'active' : ''}`}
                            onClick={() => setActiveTabOption3('slash')}
                          >
                            Slash /
                          </button>
                          <button
                            type="button"
                            className={`seg-tab ${activeTabOption3 === 'git' ? 'active' : ''}`}
                            onClick={() => setActiveTabOption3('git')}
                          >
                            Git & Shell
                          </button>
                          <button
                            type="button"
                            className={`seg-tab ${activeTabOption3 === 'custom' ? 'active' : ''}`}
                            onClick={() => setActiveTabOption3('custom')}
                          >
                            Custom ({customCommands.length})
                          </button>
                        </div>

                        {/* Large 3-Column Tab Content Grid */}
                        <div className="scrollable-command-grid grid-3col">
                          {allCommands
                            .filter((c) => c.category === activeTabOption3)
                            .map((cmd) => (
                              <button
                                key={cmd.id}
                                type="button"
                                className="sheet-card"
                                onClick={() => sendTerminalAction(cmd.title, cmd.keys)}
                              >
                                <div className="sheet-card-icon">›_</div>
                                <div className="sheet-card-title">{cmd.title}</div>
                                <div className="sheet-card-key">{cmd.keys}</div>
                              </button>
                            ))}
                          {activeTabOption3 === 'custom' && (
                            <button
                              type="button"
                              className="sheet-card sheet-add-card"
                              onClick={() => setShowAddModal(true)}
                            >
                              <div className="sheet-card-icon">+</div>
                              <div className="sheet-card-title">Add Shortcut</div>
                            </button>
                          )}
                        </div>

                        {/* Standardized Bottom Dock */}
                        <div className="standardized-dock five-slot-dock">
                          <button
                            type="button"
                            className="std-key key-esc"
                            onClick={() => sendTerminalAction('Esc', 'escape', true)}
                          >
                            Esc
                          </button>
                          <button
                            type="button"
                            className="std-key key-warn"
                            onClick={() => sendTerminalAction('Clear', 'clear', true)}
                          >
                            Clear
                          </button>
                          <button
                            type="button"
                            className="std-key"
                            onClick={() => sendTerminalAction('History', 'history', true)}
                          >
                            History
                          </button>
                          <button
                            type="button"
                            className="std-key"
                            onClick={() => sendTerminalAction('Tab', 'tab', true)}
                          >
                            Tab
                          </button>
                          <button
                            type="button"
                            className="std-key"
                            onClick={() => sendTerminalAction('⇧Tab', 'shift+tab', true)}
                          >
                            ⇧Tab
                          </button>
                          <button
                            type="button"
                            className="std-key key-return"
                            onClick={() => sendTerminalAction('Return', 'enter', true)}
                          >
                            ⏎
                          </button>
                        </div>
                      </div>
                    )}
                  </div>
                ) : (
                  /* Collapsed Input Bar Preview */
                  <div className="collapsed-input-bar">
                    <button
                      type="button"
                      className="expand-trigger-btn"
                      onClick={() => setIsExpanded(true)}
                    >
                      ⌨ Expand Command Pad
                    </button>
                    <span className="collapsed-hint">Tap to open enlarged macro grid</span>
                  </div>
                )}
              </div>
            </div>

            {/* Architecture & Evaluation Sidebar */}
            <div className="proto-sidebar">
              <div className="sidebar-card">
                <h3>
                  {option === 'option1' && 'Option 1: The Split Console'}
                  {option === 'option2' && 'Option 2: The Command Deck'}
                  {option === 'option3' && 'Option 3: The Sheet Controller'}
                </h3>
                <p className="sidebar-desc">
                  {option === 'option1' &&
                    'Preserves vertical terminal space while anchoring critical control keys directly at the bottom thumb zone.'}
                  {option === 'option2' &&
                    'Transforms the lower pane into a tactile developer controller with an illuminated D-pad on the left and a macro action deck on the right.'}
                  {option === 'option3' &&
                    'Adopts the standard iOS bottom sheet paradigm with swipeable category tabs and a standardized 5-button thumb dock.'}
                </p>

                {/* Scorecards */}
                <div className="scorecard-grid">
                  <div className="score-item">
                    <span className="score-val">
                      {option === 'option1' ? '9.5 / 10' : option === 'option2' ? '8.8 / 10' : '9.2 / 10'}
                    </span>
                    <span className="score-label">Thumb Reachability</span>
                  </div>
                  <div className="score-item">
                    <span className="score-val">
                      {option === 'option1' ? '18+ keys' : option === 'option2' ? '24+ keys' : '36+ keys'}
                    </span>
                    <span className="score-label">Command Capacity</span>
                  </div>
                  <div className="score-item">
                    <span className="score-val">
                      {option === 'option1' ? 'High' : option === 'option2' ? 'Very High' : 'High'}
                    </span>
                    <span className="score-label">Muscle Memory Lock</span>
                  </div>
                  <div className="score-item">
                    <span className="score-val">
                      {option === 'option1' ? 'Low' : option === 'option2' ? 'Medium' : 'Low'}
                    </span>
                    <span className="score-label">SwiftUI Effort</span>
                  </div>
                </div>

                {/* Architectural Elements Breakdown */}
                <div className="arch-breakdown">
                  <h4>Key Architectural Components</h4>
                  <div className="arch-row">
                    <span className="arch-badge std">Standardized Anchor</span>
                    <span className="arch-text">
                      {option === 'option1' && 'Fixed bottom rail with Esc, Tab, Arrow Keys, and Return'}
                      {option === 'option2' && 'Dedicated left thumb zone with 4-way D-Pad, Esc, Ctrl+C, Enter'}
                      {option === 'option3' && 'Persistent bottom dock: Esc, Clear, History, Tab, Return'}
                    </span>
                  </div>
                  <div className="arch-row">
                    <span className="arch-badge scroll">Scrollable & Changeable</span>
                    <span className="arch-text">
                      {option === 'option1' && 'Smooth vertical 3-column grid with live category filters'}
                      {option === 'option2' && 'Independent right deck scroll with custom slot builder'}
                      {option === 'option3' && 'Categorized tab pages (Agent Chords, Slash, Git, Custom)'}
                    </span>
                  </div>
                  <div className="arch-row">
                    <span className="arch-badge agent">Agent Adaptation</span>
                    <span className="arch-text">
                      Dynamically queries active pane agent (Claude, Codex, Cursor, Gemini) from{' '}
                      <code>agent-shortcuts.json</code> and live slash scraping.
                    </span>
                  </div>
                </div>

                {/* Action controls */}
                <div className="sidebar-actions">
                  <button
                    type="button"
                    className="action-btn"
                    onClick={() => {
                      setTerminalLines([
                        'Herdr SSH session reconnected.',
                        '[Ready for autonomous agent commands]',
                      ]);
                    }}
                  >
                    Clear Terminal Output
                  </button>
                  <button
                    type="button"
                    className="action-btn primary"
                    onClick={() => setShowAddModal(true)}
                  >
                    + Add Custom Shortcut
                  </button>
                </div>
              </div>
            </div>
          </>
        )}
      </div>

      {/* Modal for adding a custom shortcut */}
      {showAddModal && (
        <div className="modal-backdrop">
          <div className="modal-dialog">
            <h3>Add Custom Shortcut to Command Pad</h3>
            <p>Customize key chords and macros staged on the remote Herdr session.</p>

            <div className="input-group">
              <label>Key or Command Token</label>
              <input
                type="text"
                placeholder="e.g. ctrl+r, alt+down, git status, /test"
                value={newKeyInput}
                onChange={(e) => setNewKeyInput(e.target.value)}
                autoFocus
              />
              <span className="input-hint">Supported tokens: enter, tab, ctrl+c, alt+up, or slash / commands</span>
            </div>

            <div className="input-group">
              <label>Display Title (Optional)</label>
              <input
                type="text"
                placeholder="e.g. Search History, Next Diff"
                value={newTitleInput}
                onChange={(e) => setNewTitleInput(e.target.value)}
              />
            </div>

            <div className="modal-actions">
              <button
                type="button"
                className="cancel-btn"
                onClick={() => setShowAddModal(false)}
              >
                Cancel
              </button>
              <button
                type="button"
                className="submit-btn"
                onClick={addCustomShortcut}
                disabled={!newKeyInput.trim()}
              >
                Add Shortcut
              </button>
            </div>
          </div>
        </div>
      )}

      {/* Embedded Prototype Styles */}
      <style jsx>{`
        .prototype-wrapper {
          min-height: 100vh;
          background-color: #07070c;
          color: #f5f5f7;
          font-family: -apple-system, BlinkMacSystemFont, 'SF Pro Display', 'Segoe UI', Roboto, sans-serif;
          padding: 24px 32px;
          display: flex;
          flex-direction: column;
          gap: 20px;
        }

        .proto-header {
          display: flex;
          justify-content: space-between;
          align-items: center;
          flex-wrap: wrap;
          gap: 16px;
          padding-bottom: 16px;
          border-bottom: 1px solid rgba(255, 255, 255, 0.08);
        }

        .proto-header-left {
          display: flex;
          align-items: center;
          gap: 18px;
        }

        .proto-back-btn {
          color: #0edcd5;
          text-decoration: none;
          font-size: 14px;
          font-weight: 500;
          padding: 6px 12px;
          background: rgba(14, 220, 213, 0.1);
          border-radius: 8px;
          transition: background 0.2s;
        }
        .proto-back-btn:hover {
          background: rgba(14, 220, 213, 0.2);
        }

        .proto-titles h1 {
          font-size: 22px;
          font-weight: 700;
          margin: 0;
          letter-spacing: -0.02em;
        }

        .proto-titles p {
          font-size: 13px;
          color: #8e8e93;
          margin: 2px 0 0 0;
        }

        .agent-switcher-bar {
          display: flex;
          align-items: center;
          gap: 8px;
          background: #14141f;
          padding: 6px 10px;
          border-radius: 12px;
          border: 1px solid rgba(255, 255, 255, 0.06);
        }

        .agent-label {
          font-size: 12px;
          color: #8e8e93;
          font-weight: 500;
        }

        .agent-tab-btn {
          background: transparent;
          border: 1px solid transparent;
          padding: 4px 10px;
          border-radius: 8px;
          font-size: 12px;
          cursor: pointer;
          display: flex;
          align-items: center;
          gap: 6px;
          transition: all 0.15s;
        }

        .agent-tab-btn.active {
          background: rgba(255, 255, 255, 0.06);
        }

        .agent-dot {
          width: 8px;
          height: 8px;
          border-radius: 50%;
        }

        .proto-nav-pills {
          display: grid;
          grid-template-columns: repeat(auto-fit, minmax(240px, 1fr));
          gap: 12px;
        }

        .pill-btn {
          background: #12121c;
          border: 1px solid rgba(255, 255, 255, 0.08);
          border-radius: 14px;
          padding: 12px 16px;
          color: #d1d1d6;
          font-size: 14px;
          font-weight: 600;
          text-align: left;
          cursor: pointer;
          display: flex;
          flex-direction: column;
          gap: 4px;
          transition: all 0.2s;
        }

        .pill-btn:hover {
          border-color: rgba(14, 220, 213, 0.3);
          background: #181826;
        }

        .pill-btn.active {
          border-color: #0edcd5;
          background: rgba(14, 220, 213, 0.08);
          color: #ffffff;
          box-shadow: 0 0 16px rgba(14, 220, 213, 0.15);
        }

        .pill-num {
          display: inline-flex;
          align-items: center;
          justify-content: center;
          width: 20px;
          height: 20px;
          border-radius: 6px;
          background: rgba(255, 255, 255, 0.1);
          font-size: 11px;
          margin-bottom: 2px;
        }

        .pill-btn.active .pill-num {
          background: #0edcd5;
          color: #003e43;
          font-weight: 700;
        }

        .pill-badge {
          font-size: 11px;
          font-weight: 400;
          color: #8e8e93;
        }

        .proto-body-grid {
          display: grid;
          grid-template-columns: 420px 1fr;
          gap: 32px;
          align-items: start;
        }

        @media (max-width: 960px) {
          .proto-body-grid {
            grid-template-columns: 1fr;
          }
        }

        /* Phone Simulator */
        .phone-simulator-column {
          display: flex;
          justify-content: center;
        }

        .phone-device-frame {
          width: 390px;
          height: 780px;
          background: #000000;
          border-radius: 48px;
          border: 10px solid #252528;
          box-shadow: 0 25px 60px rgba(0, 0, 0, 0.8), 0 0 0 1px rgba(255, 255, 255, 0.1);
          overflow: hidden;
          display: flex;
          flex-direction: column;
          position: relative;
        }

        .phone-island {
          position: absolute;
          top: 10px;
          left: 50%;
          transform: translateX(-50%);
          width: 100px;
          height: 26px;
          background: #000;
          border-radius: 20px;
          z-index: 50;
          display: flex;
          align-items: center;
          justify-content: flex-end;
          padding-right: 12px;
        }

        .island-camera {
          width: 10px;
          height: 10px;
          background: #111;
          border-radius: 50%;
          border: 1px solid #222;
        }

        .phone-status-bar {
          display: flex;
          justify-content: space-between;
          padding: 12px 24px 4px;
          font-size: 13px;
          font-weight: 600;
          color: #fff;
          z-index: 10;
        }

        .phone-status-icons {
          display: flex;
          gap: 6px;
          font-size: 11px;
        }

        .phone-nav-header {
          display: flex;
          justify-content: space-between;
          align-items: center;
          padding: 8px 16px;
          border-bottom: 1px solid rgba(255, 255, 255, 0.08);
          background: rgba(18, 18, 24, 0.8);
          backdrop-filter: blur(20px);
        }

        .space-pill {
          font-size: 11px;
          font-family: ui-monospace, monospace;
          background: #1c1c24;
          padding: 3px 8px;
          border-radius: 6px;
          color: #d1d1d6;
          margin-right: 6px;
        }

        .agent-status-badge {
          font-size: 11px;
          font-weight: 600;
          padding: 2px 7px;
          border-radius: 6px;
          border: 1px solid;
        }

        .pane-toggle-btn {
          background: rgba(255, 255, 255, 0.1);
          border: none;
          color: #fff;
          font-size: 11px;
          padding: 4px 10px;
          border-radius: 6px;
          cursor: pointer;
        }

        /* Terminal Viewport */
        .terminal-viewport {
          flex: 1;
          background: #000000;
          padding: 12px 14px;
          overflow-y: auto;
          font-family: ui-monospace, 'SF Mono', Menlo, Consolas, monospace;
          font-size: 11.5px;
          line-height: 1.45;
          color: #a1a1aa;
        }

        .terminal-line {
          word-break: break-all;
          margin-bottom: 4px;
        }

        .line-danger {
          color: #ff453a !important;
          font-weight: 600;
        }

        .line-cyan {
          color: #0edcd5 !important;
          font-weight: 600;
        }

        .line-agent {
          color: #f5f5f7;
        }

        /* Expanded Command Pane */
        .expanded-command-pane {
          height: 380px;
          background: #161622;
          border-top: 1px solid rgba(255, 255, 255, 0.12);
          display: flex;
          flex-direction: column;
          animation: slideUp 0.25s cubic-bezier(0.16, 1, 0.3, 1);
        }

        @keyframes slideUp {
          from {
            transform: translateY(100%);
          }
          to {
            transform: translateY(0);
          }
        }

        .pane-grabber-bar {
          display: flex;
          flex-direction: column;
          align-items: center;
          padding: 8px 14px 4px;
          position: relative;
        }

        .grabber {
          width: 36px;
          height: 4px;
          background: rgba(255, 255, 255, 0.25);
          border-radius: 3px;
          margin-bottom: 4px;
        }

        .pane-header-title {
          width: 100%;
          display: flex;
          justify-content: space-between;
          align-items: center;
          font-size: 12px;
          font-weight: 600;
          color: #8e8e93;
        }

        .agent-indicator {
          font-size: 10px;
          font-weight: 700;
          padding: 2px 7px;
          border-radius: 9999px;
          display: inline-flex;
          align-items: center;
          gap: 4px;
        }

        .quick-add-btn {
          background: rgba(14, 220, 213, 0.15);
          color: #0edcd5;
          border: 1px solid rgba(14, 220, 213, 0.3);
          font-size: 10px;
          font-weight: 600;
          padding: 2px 8px;
          border-radius: 6px;
          cursor: pointer;
        }

        .dismiss-chevron-btn {
          background: rgba(255, 255, 255, 0.1);
          color: #8e8e93;
          border: none;
          width: 22px;
          height: 22px;
          border-radius: 50%;
          font-size: 13px;
          display: flex;
          align-items: center;
          justify-content: center;
          cursor: pointer;
          transition: all 0.15s;
        }

        .dismiss-chevron-btn:hover {
          background: rgba(255, 255, 255, 0.2);
          color: #fff;
        }

        /* Option 1 Layout */
        .option1-view {
          display: flex;
          flex-direction: column;
          height: 100%;
        }

        .category-filter-strip {
          display: flex;
          gap: 6px;
          padding: 4px 12px 8px;
          overflow-x: auto;
        }

        .filter-chip {
          background: #20202e;
          border: 1px solid rgba(255, 255, 255, 0.08);
          color: #a1a1aa;
          font-size: 11px;
          font-weight: 500;
          padding: 4px 10px;
          border-radius: 12px;
          cursor: pointer;
          white-space: nowrap;
        }

        .filter-chip.active {
          background: #0edcd5;
          color: #003e43;
          border-color: #0edcd5;
          font-weight: 700;
        }

        .filter-chip.add-chip {
          border-style: dashed;
          border-color: rgba(14, 220, 213, 0.4);
          color: #0edcd5;
        }

        .scrollable-command-grid {
          flex: 1;
          overflow-y: auto;
          padding: 6px 12px;
        }

        .grid-3col {
          display: grid;
          grid-template-columns: repeat(3, 1fr);
          gap: 8px;
        }

        .command-card {
          background: #20202f;
          border: 1px solid rgba(255, 255, 255, 0.08);
          border-radius: 10px;
          padding: 10px 8px;
          display: flex;
          flex-direction: column;
          align-items: center;
          justify-content: center;
          text-align: center;
          gap: 3px;
          cursor: pointer;
          transition: all 0.15s;
        }

        .command-card:active {
          transform: scale(0.96);
          background: #2b2b3d;
          border-color: #0edcd5;
        }

        .cmd-keys {
          font-family: ui-monospace, monospace;
          font-size: 12px;
          font-weight: 700;
        }

        .cmd-title {
          font-size: 10px;
          color: #d1d1d6;
          white-space: nowrap;
          overflow: hidden;
          text-overflow: ellipsis;
          max-width: 100%;
        }

        /* Standardized Dock (Bottom Row) */
        .standardized-dock {
          background: #0d0d14;
          border-top: 1px solid rgba(255, 255, 255, 0.1);
          padding: 8px 10px 14px;
          display: flex;
          gap: 6px;
        }

        .std-key {
          flex: 1;
          height: 38px;
          background: #242436;
          border: 1px solid rgba(255, 255, 255, 0.1);
          border-radius: 8px;
          color: #f5f5f7;
          font-size: 12px;
          font-weight: 600;
          display: flex;
          align-items: center;
          justify-content: center;
          cursor: pointer;
          transition: all 0.1s;
        }

        .std-key:active {
          transform: scale(0.94);
          background: #32324b;
        }

        .key-esc {
          background: #3d1c1c;
          border-color: rgba(255, 69, 58, 0.4);
          color: #ff453a;
          font-weight: 700;
        }
        .key-esc:active {
          background: #ff453a;
          color: #fff;
        }

        .key-warn {
          background: #3a2818;
          border-color: rgba(255, 159, 10, 0.4);
          color: #ff9f0a;
        }

        .key-return {
          flex: 1.5;
          background: #0edcd5;
          border-color: #0edcd5;
          color: #003e43;
          font-weight: 700;
        }
        .key-return:active {
          background: #14fff7;
        }

        /* Option 2 Dual Zone */
        .option2-view {
          display: flex;
          flex-direction: column;
          height: 100%;
        }

        .dual-zone-container {
          flex: 1;
          display: grid;
          grid-template-columns: 140px 1fr;
          gap: 8px;
          padding: 6px 10px 14px;
          overflow: hidden;
        }

        .left-thumb-zone {
          background: #12121c;
          border: 1px solid rgba(255, 255, 255, 0.08);
          border-radius: 14px;
          padding: 8px;
          display: flex;
          flex-direction: column;
          justify-content: space-between;
          gap: 6px;
        }

        .dpad-top-row {
          display: flex;
          gap: 6px;
        }

        .cross-dpad {
          display: flex;
          flex-direction: column;
          align-items: center;
          gap: 4px;
          margin-top: 4px;
        }

        .dpad-mid-row {
          display: flex;
          gap: 4px;
        }

        .dpad-btn {
          width: 36px;
          height: 36px;
          background: #1f1f2e;
          border: 1px solid rgba(14, 220, 213, 0.3);
          border-radius: 8px;
          color: #0edcd5;
          font-size: 11px;
          font-weight: 700;
          cursor: pointer;
          display: flex;
          align-items: center;
          justify-content: center;
          transition: all 0.1s;
        }

        .dpad-btn:active {
          background: #0edcd5;
          color: #003e43;
          transform: scale(0.92);
        }

        .dpad-center {
          background: #181824;
          font-size: 9px;
          color: #8e8e93;
        }

        .right-action-deck {
          overflow-y: auto;
          padding-right: 2px;
        }

        .scrollable-deck-grid {
          display: grid;
          grid-template-columns: repeat(2, 1fr);
          gap: 8px;
        }

        .deck-card {
          background: #202030;
          border: 1px solid rgba(255, 255, 255, 0.08);
          border-radius: 12px;
          padding: 8px 10px;
          text-align: left;
          cursor: pointer;
          display: flex;
          flex-direction: column;
          gap: 4px;
          transition: all 0.15s;
        }

        .deck-card:active {
          background: #2c2c40;
          border-color: #0edcd5;
          transform: scale(0.96);
        }

        .deck-card-top {
          display: flex;
          justify-content: space-between;
          align-items: center;
        }

        .deck-tag {
          font-size: 9px;
          text-transform: uppercase;
          color: #8e8e93;
          font-weight: 700;
        }

        .deck-chord {
          font-family: ui-monospace, monospace;
          font-size: 11px;
          font-weight: 700;
          color: #0edcd5;
        }

        .deck-card-title {
          font-size: 11px;
          font-weight: 500;
          color: #f5f5f7;
          line-height: 1.2;
        }

        .deck-add-card {
          border-style: dashed;
          border-color: rgba(14, 220, 213, 0.35);
          align-items: center;
          justify-content: center;
          text-align: center;
          color: #0edcd5;
          font-size: 11px;
          padding: 14px 8px;
        }

        .add-icon {
          font-size: 18px;
          font-weight: 700;
        }

        /* Option 3 View */
        .option3-view {
          display: flex;
          flex-direction: column;
          height: 100%;
        }

        .segmented-tab-row {
          display: flex;
          margin: 4px 12px 8px;
          background: #111118;
          border-radius: 10px;
          padding: 3px;
          border: 1px solid rgba(255, 255, 255, 0.08);
        }

        .seg-tab {
          flex: 1;
          background: transparent;
          border: none;
          color: #8e8e93;
          font-size: 11px;
          font-weight: 600;
          padding: 6px 4px;
          border-radius: 7px;
          cursor: pointer;
          transition: all 0.15s;
        }

        .seg-tab.active {
          background: #242436;
          color: #0edcd5;
          box-shadow: 0 2px 6px rgba(0, 0, 0, 0.3);
        }

        .sheet-card {
          background: #1c1c2a;
          border: 1px solid rgba(255, 255, 255, 0.08);
          border-radius: 12px;
          padding: 10px 8px;
          display: flex;
          flex-direction: column;
          align-items: center;
          gap: 2px;
          cursor: pointer;
          transition: all 0.15s;
        }

        .sheet-card:active {
          border-color: #0edcd5;
          transform: scale(0.96);
          background: #26263b;
        }

        .sheet-card-icon {
          font-family: ui-monospace, monospace;
          font-size: 14px;
          font-weight: 700;
          color: #0edcd5;
        }

        .sheet-card-title {
          font-size: 10.5px;
          color: #fff;
          font-weight: 500;
          text-align: center;
        }

        .sheet-card-key {
          font-size: 9.5px;
          color: #8e8e93;
          font-family: ui-monospace, monospace;
        }

        .sheet-add-card {
          border-style: dashed;
          border-color: rgba(14, 220, 213, 0.35);
          color: #0edcd5;
        }

        .five-slot-dock {
          padding-bottom: 16px;
        }

        /* Collapsed Bar */
        .collapsed-input-bar {
          background: #161622;
          padding: 16px;
          display: flex;
          flex-direction: column;
          align-items: center;
          gap: 6px;
          border-top: 1px solid rgba(255, 255, 255, 0.1);
        }

        .expand-trigger-btn {
          background: #0edcd5;
          color: #003e43;
          border: none;
          font-size: 13px;
          font-weight: 700;
          padding: 10px 20px;
          border-radius: 10px;
          cursor: pointer;
          box-shadow: 0 4px 14px rgba(14, 220, 213, 0.3);
        }

        .collapsed-hint {
          font-size: 11px;
          color: #8e8e93;
        }

        /* Sidebar Styles */
        .proto-sidebar {
          display: flex;
          flex-direction: column;
          gap: 16px;
        }

        .sidebar-card {
          background: #13131e;
          border: 1px solid rgba(255, 255, 255, 0.08);
          border-radius: 20px;
          padding: 24px;
        }

        .sidebar-card h3 {
          font-size: 18px;
          font-weight: 700;
          margin: 0 0 8px 0;
          color: #0edcd5;
        }

        .sidebar-desc {
          font-size: 14px;
          color: #a1a1aa;
          line-height: 1.5;
          margin: 0 0 20px 0;
        }

        .scorecard-grid {
          display: grid;
          grid-template-columns: repeat(2, 1fr);
          gap: 12px;
          margin-bottom: 24px;
        }

        .score-item {
          background: #1a1a28;
          border: 1px solid rgba(255, 255, 255, 0.06);
          border-radius: 12px;
          padding: 12px;
          display: flex;
          flex-direction: column;
          gap: 4px;
        }

        .score-val {
          font-size: 16px;
          font-weight: 700;
          color: #fff;
        }

        .score-label {
          font-size: 11px;
          color: #8e8e93;
        }

        .arch-breakdown {
          border-top: 1px solid rgba(255, 255, 255, 0.08);
          padding-top: 18px;
          display: flex;
          flex-direction: column;
          gap: 12px;
        }

        .arch-breakdown h4 {
          font-size: 13px;
          text-transform: uppercase;
          letter-spacing: 0.05em;
          color: #8e8e93;
          margin: 0;
        }

        .arch-row {
          display: flex;
          flex-direction: column;
          gap: 4px;
        }

        .arch-badge {
          display: inline-block;
          font-size: 10.5px;
          font-weight: 700;
          padding: 2px 8px;
          border-radius: 6px;
          width: fit-content;
        }

        .arch-badge.std {
          background: rgba(255, 69, 58, 0.15);
          color: #ff453a;
          border: 1px solid rgba(255, 69, 58, 0.3);
        }

        .arch-badge.scroll {
          background: rgba(14, 220, 213, 0.15);
          color: #0edcd5;
          border: 1px solid rgba(14, 220, 213, 0.3);
        }

        .arch-badge.agent {
          background: rgba(143, 118, 178, 0.15);
          color: #8f76b2;
          border: 1px solid rgba(143, 118, 178, 0.3);
        }

        .arch-text {
          font-size: 13px;
          color: #d1d1d6;
          line-height: 1.4;
        }

        .arch-text code {
          font-family: ui-monospace, monospace;
          background: #20202e;
          padding: 2px 6px;
          border-radius: 4px;
          font-size: 12px;
          color: #0edcd5;
        }

        .sidebar-actions {
          display: flex;
          gap: 10px;
          margin-top: 24px;
        }

        .action-btn {
          flex: 1;
          padding: 10px 14px;
          border-radius: 10px;
          font-size: 13px;
          font-weight: 600;
          cursor: pointer;
          background: #20202e;
          color: #d1d1d6;
          border: 1px solid rgba(255, 255, 255, 0.1);
          transition: all 0.15s;
        }

        .action-btn:hover {
          background: #28283a;
        }

        .action-btn.primary {
          background: #0edcd5;
          color: #003e43;
          border-color: #0edcd5;
          font-weight: 700;
        }

        .action-btn.primary:hover {
          background: #14fff7;
        }

        /* Gallery View Styles */
        .gallery-full-container {
          grid-column: 1 / -1;
          display: flex;
          flex-direction: column;
          gap: 24px;
        }

        .gallery-header h2 {
          font-size: 22px;
          font-weight: 700;
          margin: 0 0 6px 0;
          color: #fff;
        }

        .gallery-header p {
          color: #8e8e93;
          font-size: 14px;
          margin: 0;
        }

        .gallery-grid {
          display: grid;
          grid-template-columns: repeat(auto-fit, minmax(320px, 1fr));
          gap: 24px;
        }

        .gallery-card {
          background: #14141f;
          border: 1px solid rgba(255, 255, 255, 0.08);
          border-radius: 20px;
          overflow: hidden;
          display: flex;
          flex-direction: column;
        }

        .gallery-img-container {
          background: #000;
          display: flex;
          justify-content: center;
          padding: 16px;
          border-bottom: 1px solid rgba(255, 255, 255, 0.08);
        }

        .gallery-img {
          width: 100%;
          max-width: 260px;
          height: auto;
          border-radius: 24px;
          box-shadow: 0 10px 30px rgba(0, 0, 0, 0.7);
        }

        .gallery-info {
          padding: 20px;
          display: flex;
          flex-direction: column;
          gap: 10px;
          flex: 1;
        }

        .gallery-tag {
          font-size: 11px;
          font-weight: 700;
          padding: 3px 8px;
          border-radius: 6px;
          width: fit-content;
        }

        .option1-tag {
          background: rgba(14, 220, 213, 0.15);
          color: #0edcd5;
        }
        .option2-tag {
          background: rgba(255, 214, 10, 0.15);
          color: #ffd60a;
        }
        .option3-tag {
          background: rgba(143, 118, 178, 0.15);
          color: #8f76b2;
        }

        .gallery-info h3 {
          font-size: 16px;
          font-weight: 700;
          margin: 0;
          color: #fff;
        }

        .gallery-info p {
          font-size: 13px;
          color: #a1a1aa;
          line-height: 1.45;
          margin: 0;
        }

        .gallery-info ul {
          margin: 4px 0 12px 0;
          padding-left: 18px;
          font-size: 12.5px;
          color: #d1d1d6;
          line-height: 1.5;
        }

        .try-in-sim-btn {
          margin-top: auto;
          background: #202030;
          border: 1px solid rgba(14, 220, 213, 0.3);
          color: #0edcd5;
          font-size: 13px;
          font-weight: 600;
          padding: 10px;
          border-radius: 10px;
          cursor: pointer;
          transition: all 0.2s;
        }

        .try-in-sim-btn:hover {
          background: #0edcd5;
          color: #003e43;
        }

        /* Modal Styles */
        .modal-backdrop {
          position: fixed;
          top: 0;
          left: 0;
          right: 0;
          bottom: 0;
          background: rgba(0, 0, 0, 0.75);
          backdrop-filter: blur(10px);
          display: flex;
          align-items: center;
          justify-content: center;
          z-index: 100;
        }

        .modal-dialog {
          background: #181824;
          border: 1px solid rgba(255, 255, 255, 0.12);
          border-radius: 20px;
          width: 90%;
          max-width: 440px;
          padding: 24px;
          display: flex;
          flex-direction: column;
          gap: 16px;
          box-shadow: 0 20px 50px rgba(0, 0, 0, 0.6);
        }

        .modal-dialog h3 {
          margin: 0;
          font-size: 17px;
          color: #fff;
        }

        .modal-dialog p {
          margin: 0;
          font-size: 13px;
          color: #8e8e93;
        }

        .input-group {
          display: flex;
          flex-direction: column;
          gap: 6px;
        }

        .input-group label {
          font-size: 12px;
          font-weight: 600;
          color: #d1d1d6;
        }

        .input-group input {
          background: #101018;
          border: 1px solid rgba(255, 255, 255, 0.12);
          border-radius: 10px;
          padding: 10px 12px;
          color: #fff;
          font-size: 13px;
          outline: none;
        }

        .input-group input:focus {
          border-color: #0edcd5;
        }

        .input-hint {
          font-size: 11px;
          color: #636366;
        }

        .modal-actions {
          display: flex;
          justify-content: flex-end;
          gap: 10px;
          margin-top: 8px;
        }

        .cancel-btn {
          background: transparent;
          border: 1px solid rgba(255, 255, 255, 0.1);
          color: #8e8e93;
          padding: 8px 14px;
          border-radius: 8px;
          cursor: pointer;
        }

        .submit-btn {
          background: #0edcd5;
          color: #003e43;
          border: none;
          font-weight: 700;
          padding: 8px 16px;
          border-radius: 8px;
          cursor: pointer;
        }

        .submit-btn:disabled {
          opacity: 0.5;
          cursor: not-allowed;
        }
      `}</style>
    </div>
  );
}
