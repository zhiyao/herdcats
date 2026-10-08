'use client';

import { useEffect, useState } from 'react';
import { Moon, Sun } from 'lucide-react';
import { THEME_STORAGE_KEY, onThemeChange, type ThemeName } from '@/lib/scenery';

/** Night/day switch (DESIGN.md §6, Theme toggle): moon · track · sun. Night is the default. */
export function ThemeToggle() {
  const [theme, setTheme] = useState<ThemeName>('dark');

  useEffect(() => {
    setTheme(document.documentElement.dataset.theme === 'light' ? 'light' : 'dark');
    return onThemeChange(setTheme);
  }, []);

  const toggle = () => {
    const next: ThemeName = theme === 'light' ? 'dark' : 'light';
    document.documentElement.dataset.theme = next;
    try {
      localStorage.setItem(THEME_STORAGE_KEY, next);
    } catch {
      // Storage can be unavailable (private mode); the switch still works for this visit.
    }
  };

  return (
    <button
      type="button"
      role="switch"
      aria-checked={theme === 'light'}
      aria-label="Light mode"
      className="theme-toggle"
      onClick={toggle}
    >
      <Moon size={18} strokeWidth={2.25} aria-hidden="true" />
      <span className="theme-toggle-track" data-on={theme === 'light'}>
        <span className="theme-toggle-knob" />
      </span>
      <Sun size={18} strokeWidth={2.25} aria-hidden="true" />
    </button>
  );
}
