'use client';

import React, { useEffect, useRef } from 'react';
import { World } from '@/lib/world';
import { Cat, CAT_THEMES, CAT_STATES } from '@/lib/cats';
import { soundSystem } from '@/lib/audio';

export interface CatCanvasHandle {
  scatterHerd: () => void;
  triggerCheatWin: () => void;
}

interface CatCanvasProps {
  onVictory: () => void;
  gameWon: boolean;
  onRef?: (handle: CatCanvasHandle) => void;
}

export function CatCanvas({ onVictory, gameWon, onRef }: CatCanvasProps) {
  const containerRef = useRef<HTMLDivElement | null>(null);
  const worldRef = useRef<World | null>(null);
  const catsRef = useRef<Cat[]>([]);
  const gameWonRef = useRef(gameWon);

  useEffect(() => {
    gameWonRef.current = gameWon;
  }, [gameWon]);

  useEffect(() => {
    const container = containerRef.current;
    if (!container) return;

    // 1. Initialize the flat pixel-art meadow
    const world = new World(container);
    worldRef.current = world;

    // 2. Spawn 10 Independent Meadow Cats
    const cats: Cat[] = [];
    const totalCats = CAT_THEMES.length;

    CAT_THEMES.forEach((theme, index) => {
      const angle = (index / totalCats) * Math.PI * 2 + (Math.random() - 0.5) * 0.3;
      const distance = 9.0 + Math.random() * 8.0;
      const startX = Math.cos(angle) * distance;
      const startZ = Math.sin(angle) * distance;

      const cat = new Cat(theme, startX, startZ);
      cats.push(cat);
    });
    catsRef.current = cats;

    // 3. Pointer to ground plane & Herding Physics
    let prevMousePos: { x: number; z: number } | null = null;
    let mouseVelocity = 0;
    let isPointerDown = false;

    function updatePointer(clientX: number, clientY: number) {
      const point = world.toGround(clientX, clientY);
      if (prevMousePos) {
        mouseVelocity = Math.hypot(point.x - prevMousePos.x, point.z - prevMousePos.z);
      }
      prevMousePos = point;

      const pointerDownBoost = isPointerDown ? 1.4 : 1.0;
      const pushBoost = Math.min(2.5, (1.0 + mouseVelocity * 1.5) * pointerDownBoost);

      cats.forEach((cat) => {
        if (!cat.corralled) {
          cat.applyHerdingForce(point.x, point.z, pushBoost);
        }
      });
    }

    const onPointerMove = (e: PointerEvent) => updatePointer(e.clientX, e.clientY);
    const onPointerDown = (e: PointerEvent) => {
      isPointerDown = true;
      soundSystem.resume();
      updatePointer(e.clientX, e.clientY);
    };
    const onPointerUp = () => {
      isPointerDown = false;
    };
    const onTouchMove = (e: TouchEvent) => {
      if (e.touches.length > 0) {
        e.preventDefault();
        updatePointer(e.touches[0].clientX, e.touches[0].clientY);
      }
    };

    container.addEventListener('pointermove', onPointerMove);
    container.addEventListener('pointerdown', onPointerDown);
    window.addEventListener('pointerup', onPointerUp);
    container.addEventListener('touchmove', onTouchMove, { passive: false });

    // 4. Scatter Herd / Reset
    function scatterHerd() {
      cats.forEach((cat, index) => {
        cat.corralled = false;
        const angle = (index / totalCats) * Math.PI * 2 + (Math.random() - 0.5) * 0.4;
        const distance = 9.5 + Math.random() * 8.0;
        cat.position = { x: Math.cos(angle) * distance, z: Math.sin(angle) * distance };
        cat.velocity = { x: 0, z: 0 };
        cat.state = CAT_STATES.WANDER;
        cat.pickNewTarget();
      });
    }

    // 5. Victory celebration
    function winGame() {
      if (gameWonRef.current) return;
      soundSystem.victoryFanfare();
      cats.forEach((cat) => {
        cat.state = CAT_STATES.LOAF;
        cat.showBubble("Meow! 🏆", 6.0);
      });
      onVictory();
    }

    // 6. Cheat win for testing
    function triggerCheatWin() {
      cats.forEach((c) => {
        c.position = { x: (Math.random() - 0.5) * 6, z: (Math.random() - 0.5) * 6 };
        c.markCorralled();
      });
      winGame();
    }

    // Expose handle to parent component
    if (onRef) {
      onRef({
        scatterHerd,
        triggerCheatWin,
      });
    }

    // Global developer shortcut 'W'
    const onKeyDown = (e: KeyboardEvent) => {
      if (e.key === 'w' || e.key === 'W') {
        triggerCheatWin();
      }
    };
    window.addEventListener('keydown', onKeyDown);

    // 7. Simulation Animation Loop
    let animationFrameId: number;
    let lastTime = performance.now();

    function animate(now: number) {
      animationFrameId = requestAnimationFrame(animate);
      const delta = Math.min((now - lastTime) / 1000, 0.1);
      lastTime = now;

      // Update cats with collision resolution
      cats.forEach((cat) => cat.update(delta, cats, world));

      // Check corral status
      let corralledCount = 0;
      cats.forEach((cat) => {
        if (cat.corralled) {
          corralledCount++;
        } else if (world.isInsideFence(cat.position)) {
          cat.markCorralled();
          corralledCount++;
        }
      });

      if (corralledCount === totalCats && !gameWonRef.current) {
        winGame();
      }

      world.render(cats);
    }

    animationFrameId = requestAnimationFrame(animate);

    return () => {
      cancelAnimationFrame(animationFrameId);
      container.removeEventListener('pointermove', onPointerMove);
      container.removeEventListener('pointerdown', onPointerDown);
      window.removeEventListener('pointerup', onPointerUp);
      container.removeEventListener('touchmove', onTouchMove);
      window.removeEventListener('keydown', onKeyDown);
      world.destroy();
    };
  }, [onVictory, onRef]);

  return <div ref={containerRef} id="canvas-container" />;
}
