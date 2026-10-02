'use client';

import React, { useEffect, useRef } from 'react';

interface VictoryModalProps {
  isOpen: boolean;
  onPlayAgain: () => void;
}

export function VictoryModal({ isOpen, onPlayAgain }: VictoryModalProps) {
  const dialogRef = useRef<HTMLDivElement | null>(null);
  const buttonRef = useRef<HTMLButtonElement | null>(null);
  const previousActiveElement = useRef<HTMLElement | null>(null);

  useEffect(() => {
    if (!isOpen) return;

    previousActiveElement.current = document.activeElement as HTMLElement | null;
    buttonRef.current?.focus();

    function handleKeyDown(e: KeyboardEvent) {
      if (e.key === 'Escape') {
        onPlayAgain();
        return;
      }
      if (e.key === 'Tab') {
        const dialog = dialogRef.current;
        if (!dialog) return;

        const focusable = dialog.querySelectorAll<HTMLElement>(
          'button:not([disabled]), [href], input:not([disabled]), select:not([disabled]), textarea:not([disabled]), [tabindex]:not([tabindex="-1"])'
        );
        if (focusable.length === 0) {
          e.preventDefault();
          return;
        }

        const first = focusable[0];
        const last = focusable[focusable.length - 1];

        if (e.shiftKey) {
          if (document.activeElement === first || !dialog.contains(document.activeElement)) {
            e.preventDefault();
            last.focus();
          }
        } else {
          if (document.activeElement === last || !dialog.contains(document.activeElement)) {
            e.preventDefault();
            first.focus();
          }
        }
      }
    }

    window.addEventListener('keydown', handleKeyDown);
    return () => {
      window.removeEventListener('keydown', handleKeyDown);
      previousActiveElement.current?.focus();
    };
  }, [isOpen, onPlayAgain]);

  if (!isOpen) return null;

  return (
    <div className="victory-overlay active">
      <div
        ref={dialogRef}
        className="victory-card"
        role="dialog"
        aria-modal="true"
        aria-labelledby="victory-title"
      >
        <div className="victory-badge-icon" aria-hidden="true">🐱</div>
        <h2 id="victory-title" className="victory-title">Herd corralled</h2>

        <div className="victory-message-quote">
          &quot;Can you imagine a herd of cats waiting to be sheared? Meow! Meow! Whoo hoo hoo&quot;
        </div>

        <p className="victory-sub">
          Every cat is in the corral. Your agents won&rsquo;t stay this tidy.
        </p>

        <button ref={buttonRef} type="button" className="victory-btn" onClick={onPlayAgain}>
          Release the herd
        </button>
      </div>
    </div>
  );
}
