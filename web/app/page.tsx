'use client';

import React, { useState, useRef, useCallback } from 'react';
import Link from 'next/link';
import dynamic from 'next/dynamic';
import { VictoryModal } from '@/components/VictoryModal';
import { ConfettiCanvas } from '@/components/ConfettiCanvas';
import type { CatCanvasHandle } from '@/components/CatCanvas';

// Dynamic import with SSR disabled for the client-only canvas
const CatCanvas = dynamic(
  () => import('@/components/CatCanvas').then((mod) => mod.CatCanvas),
  { ssr: false }
);

export default function Home() {
  const [gameWon, setGameWon] = useState(false);

  const canvasHandleRef = useRef<CatCanvasHandle | null>(null);

  const handleVictory = useCallback(() => {
    setGameWon(true);
  }, []);

  const handlePlayAgain = useCallback(() => {
    setGameWon(false);
    canvasHandleRef.current?.scatterHerd();
  }, []);

  return (
    <main>
      {/* Interactive pixel-art herding canvas */}
      <CatCanvas
        onVictory={handleVictory}
        gameWon={gameWon}
        onRef={(handle) => {
          canvasHandleRef.current = handle;
        }}
      />

      {/* UI Overlay Layer */}
      <div id="ui-layer" inert={gameWon ? true : undefined}>
        {/* Footer Links */}
        <nav className="bottom-left-links" aria-label="Legal">
          <Link href="/support" className="text-link text-link-primary">
            Support
          </Link>
          <span className="link-separator">•</span>
          <Link href="/about" className="text-link">
            About
          </Link>
          <span className="link-separator">•</span>
          <Link href="/privacy" className="text-link">
            Privacy Policy
          </Link>
          <span className="link-separator">•</span>
          <Link href="/terms" className="text-link">
            Terms
          </Link>
          <span className="link-separator">•</span>
          <a
            href="https://github.com/zhiyao/herdcats"
            target="_blank"
            rel="noopener noreferrer"
            className="text-link"
          >
            GitHub ↗
          </a>
        </nav>

        {/* App title, intro, and TestFlight link */}
        <div className="ui-column ui-column-center">
          <div className="glass-card title-card">
            {/* Brand Title */}
            <div className="brand-header">
              <img
                src="/assets/logo.svg"
                alt=""
                className="brand-logo"
                width={44}
                height={44}
              />
              <h1 className="brand-title">Herdcats</h1>
            </div>

            <p className="brand-subtitle">
              Tame your autonomous agents from your pocket.
            </p>

            <p className="brand-description">
              Herding AI agents used to feel impossible the moment you stepped away from your desk. Herdcats connects directly to Herdr over SSH so you can monitor progress, unblock agents, and keep the herd moving — right from your iPhone.
            </p>

            <a
              href="https://testflight.apple.com/join/nUr62QY1"
              target="_blank"
              rel="noopener noreferrer"
              className="btn-primary"
            >
              Join the TestFlight ↗
            </a>
          </div>
        </div>
      </div>

      {/* VICTORY CELEBRATION MODAL */}
      <VictoryModal isOpen={gameWon} onPlayAgain={handlePlayAgain} />

      {/* Confetti Canvas for Victory Shower */}
      <ConfettiCanvas active={gameWon} />
    </main>
  );
}
