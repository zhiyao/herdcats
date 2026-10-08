/**
 * Moonlit pixel backdrop shared by the landing meadow and the page headers.
 * Teal sky, a mint moon (a paper sun by day), dithered far hills, a pine treeline on the horizon,
 * and optional ground and foreground foliage. Depth comes from stepping down
 * the teal ramp; the only blend is a checkerboard dither (see DESIGN.md).
 */

// "Moonlit" palette from DESIGN.md.
export const PALETTE = {
    night950: '#1B282E',
    night900: '#26343D',
    night800: '#325156',
    teal600: '#4C777D',
    teal400: '#63988E',
    mint200: '#ABE0B6',
    paper50: '#F8F8F8',
    lacquer900: '#4B221C',
};

export type ThemeName = 'dark' | 'light';

/** Colours for each scenery layer, back to front. */
interface SceneryPalette {
    sky: string;
    moon: string;
    /** Halo colour as an `rgba(r, g, b, ` prefix; alpha is appended per ring. */
    halo: string;
    cloud: string;
    hills: string;
    trees: string;
    ground: string;
    foreground: string;
}

const SCENERY: Record<ThemeName, SceneryPalette> = {
    // Night: darker means closer; the mint moon is the only light.
    dark: {
        sky: PALETTE.teal600,
        moon: PALETTE.mint200,
        halo: 'rgba(171, 224, 182, ',
        cloud: PALETTE.teal400,
        hills: PALETTE.night800,
        trees: PALETTE.night900,
        ground: PALETTE.night800,
        foreground: PALETTE.night950,
    },
    // Day: same hues with the ramp inverted; a paper-white sun and clouds.
    light: {
        sky: '#D3EBDD',
        moon: PALETTE.paper50,
        halo: 'rgba(248, 248, 248, ',
        cloud: PALETTE.paper50,
        hills: PALETTE.mint200,
        trees: PALETTE.teal400,
        ground: '#A9CFBB',
        foreground: PALETTE.teal600,
    },
};

/** localStorage key for the light/dark choice, read by the pre-paint script in layout.tsx. */
export const THEME_STORAGE_KEY = 'herdcats-theme';

/** The theme the page is showing, from `<html data-theme>` (set before first paint in layout.tsx). */
export function currentTheme(): ThemeName {
    return document.documentElement.dataset.theme === 'light' ? 'light' : 'dark';
}

/** Calls `callback` whenever the page theme changes; returns an unsubscribe function. */
export function onThemeChange(callback: (theme: ThemeName) => void): () => void {
    const observer = new MutationObserver(() => callback(currentTheme()));
    observer.observe(document.documentElement, { attributes: true, attributeFilter: ['data-theme'] });
    return () => observer.disconnect();
}

export interface SceneryOptions {
    width: number;
    height: number;
    /** Screen y of the horizon line where the treeline stands. */
    horizon: number;
    /** Size of one scenery pixel in screen pixels. */
    pixel: number;
    moon: { x: number; y: number; r: number };
    /** Fill below the horizon with ground and add foliage in the bottom corners. */
    ground?: boolean;
    theme?: ThemeName;
    /** Leave the upper-left sky clear (page headers put their title there). */
    clearLeft?: boolean;
}

/** Deterministic PRNG so the scenery is identical on every resize. */
export function seeded(seed: number): () => number {
    return () => {
        seed = (seed + 0x6d2b79f5) | 0;
        let t = Math.imul(seed ^ (seed >>> 15), 1 | seed);
        t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
        return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
    };
}

export function drawNightScenery(ctx: CanvasRenderingContext2D, options: SceneryOptions): void {
    const { width: W, height: H, horizon, pixel: P, moon } = options;
    const rand = seeded(7);
    const colors = SCENERY[options.theme ?? 'dark'];
    const fill = (x: number, y: number, w: number, h: number, color: string) => {
        ctx.fillStyle = color;
        ctx.fillRect(Math.round(x / P) * P, Math.round(y / P) * P, Math.max(P, Math.round(w / P) * P), Math.max(P, Math.round(h / P) * P));
    };
    const columns = Math.ceil(W / P) + 1;
    const skyH = Math.max(horizon, 1);

    // Sky.
    ctx.fillStyle = colors.sky;
    ctx.fillRect(0, 0, W, H);

    // Moon with a stepped halo.
    const moonR = Math.round(moon.r / P) * P;
    const disc = (r: number, color: string) => {
        for (let dy = -r; dy <= r; dy += P) {
            const half = Math.floor(Math.sqrt(Math.max(0, r * r - dy * dy)) / P) * P;
            fill(moon.x - half, moon.y + dy, half * 2, P, color);
        }
    };
    disc(moonR * 1.7, `${colors.halo}0.06)`);
    disc(moonR * 1.35, `${colors.halo}0.08)`);
    disc(moonR, colors.moon);

    // Wispy clouds drifting across the moon and the sky, dithered at the ends.
    const cloud = (cx: number, cy: number, w: number) => {
        const rows = [w * 0.55, w, w * 0.7];
        rows.forEach((rw, i) => {
            const left = cx - rw / 2 + (i - 1) * w * 0.12;
            fill(left, cy + i * P, rw, P, colors.cloud);
            for (let d = 1; d <= 4; d++) {
                if ((d + i) % 2 === 0) {
                    fill(left - d * P, cy + i * P, P, P, colors.cloud);
                    fill(left + rw + (d - 1) * P, cy + i * P, P, P, colors.cloud);
                }
            }
        });
    };
    cloud(moon.x - moonR * 0.4, moon.y + moonR * 0.45, moonR * 2.6);
    if (!options.clearLeft) cloud(W * 0.14, skyH * 0.42, Math.min(220, W * 0.18));
    cloud(W * 0.9, skyH * 0.7, Math.min(160, W * 0.14));

    // Far hills: a rolling ridge, dithered against the sky along its crest.
    for (let i = 0; i < columns; i++) {
        const x = i * P;
        const top = horizon - skyH * 0.45 * (0.55 + 0.3 * Math.sin(x * 0.004 + 1.1) + 0.15 * Math.sin(x * 0.013 + 2.53));
        fill(x, top, P, horizon - top + P, colors.hills);
        // Checkerboard dither for the two pixels above the crest.
        if (i % 2 === 0) fill(x, top - P, P, P, colors.hills);
        if (i % 2 === 1) fill(x, top - 2 * P, P, P, colors.hills);
    }

    // Pine treeline sitting on the horizon: overlapping stepped triangles.
    const tops = new Array<number>(columns).fill(horizon - skyH * 0.03);
    let x = 0;
    while (x < W + P * 10) {
        const h = skyH * (0.08 + rand() * 0.14);
        const cx = Math.round(x / P);
        const halfW = Math.ceil(h / (2.2 * P));
        for (let dx = -halfW; dx <= halfW; dx++) {
            const col = cx + dx;
            if (col < 0 || col >= columns) continue;
            // Branch tiers: the slope steps out every two columns.
            const tier = Math.floor(Math.abs(dx) / 2) * 2;
            tops[col] = Math.min(tops[col], horizon - h + tier * P * 2.2 + (Math.abs(dx) % 2) * P);
        }
        // Trunk tip pixel above the crown.
        if (cx >= 0 && cx < columns) tops[cx] = Math.min(tops[cx], horizon - h - P);
        x += P * Math.max(2, Math.round(halfW * 0.9) + Math.floor(rand() * 3));
    }
    tops.forEach((top, i) => fill(i * P, top, P, horizon - top + P, colors.trees));

    if (!options.ground) return;

    // Ground in front of the treeline.
    fill(0, horizon, W, H - horizon, colors.ground);

    // Foreground foliage: clustered pixel domes in the bottom corners, tufts along the edge.
    const dome = (cx: number, by: number, r: number) => {
        for (let dy = 0; dy <= r; dy += P) {
            const half = Math.floor(Math.sqrt(Math.max(0, r * r - dy * dy)) / P) * P;
            fill(cx - half, by - dy, half * 2, P, colors.foreground);
        }
    };
    const bushR = Math.min(120, Math.max(40, W * 0.07));
    const cluster = (cx: number, dir: number) => {
        dome(cx, H + bushR * 0.3, bushR * 1.3);
        dome(cx + dir * bushR * 1.1, H + bushR * 0.2, bushR * 0.9);
        dome(cx + dir * bushR * 0.4, H - bushR * 0.6, bushR * 0.7);
        dome(cx + dir * bushR * 1.9, H + bushR * 0.1, bushR * 0.55);
    };
    cluster(0, 1);
    cluster(W, -1);
    for (let gx = 0; gx < W; gx += P * (3 + Math.floor(rand() * 5))) {
        const gh = P * (1 + Math.floor(rand() * 2));
        fill(gx, H - gh, P, gh, colors.foreground);
        fill(gx + P, H - gh + P, P, gh, colors.foreground);
    }
}
