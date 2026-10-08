'use client';

import { useEffect, useRef } from 'react';
import { currentTheme, drawNightScenery, onThemeChange } from '@/lib/scenery';

/** Decorative moonlit banner that fills its parent; the treeline sits on the bottom edge. */
export function PixelHorizon() {
  const canvasRef = useRef<HTMLCanvasElement | null>(null);

  useEffect(() => {
    const canvas = canvasRef.current;
    const parent = canvas?.parentElement;
    const ctx = canvas?.getContext('2d');
    if (!canvas || !parent || !ctx) return;

    const draw = () => {
      const dpr = Math.min(window.devicePixelRatio || 1, 2);
      const width = parent.clientWidth;
      const height = parent.clientHeight;
      canvas.width = Math.round(width * dpr);
      canvas.height = Math.round(height * dpr);
      ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
      ctx.imageSmoothingEnabled = false;

      const narrow = width < 700;
      const r = narrow ? 16 : 30;
      drawNightScenery(ctx, {
        width,
        height,
        horizon: height,
        pixel: narrow ? 2 : 4,
        moon: { x: narrow ? width - r * 2.4 : width * 0.8, y: narrow ? 120 : height * 0.36, r },
        clearLeft: true,
        theme: currentTheme(),
      });
    };

    draw();
    const observer = new ResizeObserver(draw);
    observer.observe(parent);
    const stopThemeWatch = onThemeChange(draw);
    return () => {
      observer.disconnect();
      stopThemeWatch();
    };
  }, []);

  return <canvas ref={canvasRef} className="pixel-horizon" aria-hidden="true" />;
}
