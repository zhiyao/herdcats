/**
 * Flat pixel-art meadow and center fence for Herdcats.
 * Mirrors the iOS empty states (`OfflineHerdView`, `LazyCatLoadingView`):
 * a 2D canvas, whole-pixel blocks, a quiet ring, and no 3D engine.
 */

import type { Cat } from './cats';

export interface Vec {
    x: number;
    z: number;
}

export interface BoxCollider {
    minX: number;
    maxX: number;
    minZ: number;
    maxZ: number;
}

export interface CircleCollider {
    x: number;
    z: number;
    r: number;
}

/** Screen projection shared by the world and the cats. */
export interface View {
    /** Screen pixels per world unit. */
    scale: number;
    /** Sprite pixel size in screen pixels; everything snaps to this grid. */
    pixel: number;
    project: (x: number, z: number, height?: number) => { sx: number; sy: number };
    snap: (value: number) => number;
}

// Ground plane is viewed from above at a slant, like the iOS herd ring.
const GROUND_TILT = 0.62;
const MEADOW_RADIUS = 25;

const COLORS = {
    background: '#000000',
    border: 'rgba(255, 255, 255, 0.12)',
    dot: 'rgba(255, 255, 255, 0.05)',
    accent: '#0EDCD5',
    pad: 'rgba(14, 220, 213, 0.07)',
    post: '#87664D',
    postTop: '#A07855',
    rail: '#A07855',
    railTop: '#C7A37A',
    beam: '#5C3E2A',
    sign: '#1F1F2E',
    box: '#B58E62',
    boxTop: '#CBA57A',
    rope: '#E2CBA8',
    ropeShade: '#B8A07F',
    base: '#3A3A52',
    rock: '#2A2A3D',
    rockTop: '#3A3A52',
};

interface Prop {
    z: number;
    draw: (ctx: CanvasRenderingContext2D) => void;
}

export class World {
    public container: HTMLElement;
    public canvas: HTMLCanvasElement;
    public ctx: CanvasRenderingContext2D;
    public view!: View;
    public fenceColliders: BoxCollider[] = [];
    public circleColliders: CircleCollider[] = [];

    private width = 0;
    private height = 0;
    private originX = 0;
    private originY = 0;
    private props: Prop[] = [];
    private groundLayer: HTMLCanvasElement | null = null;
    private resizeHandler: () => void;

    constructor(container: HTMLElement) {
        this.container = container;
        this.canvas = document.createElement('canvas');
        this.canvas.style.display = 'block';
        this.canvas.style.width = '100%';
        this.canvas.style.height = '100%';
        container.appendChild(this.canvas);

        const ctx = this.canvas.getContext('2d');
        if (!ctx) throw new Error('2D canvas is unavailable');
        this.ctx = ctx;

        this.buildColliders();
        this.onWindowResize();

        this.resizeHandler = () => this.onWindowResize();
        window.addEventListener('resize', this.resizeHandler);
    }

    private buildColliders(): void {
        const gateHalf = 2.4;
        this.fenceColliders = [
            // North, West, East walls
            { minX: -5.7, maxX: 5.7, minZ: -5.7, maxZ: -5.3 },
            { minX: -5.7, maxX: -5.3, minZ: -5.7, maxZ: 5.7 },
            { minX: 5.3, maxX: 5.7, minZ: -5.7, maxZ: 5.7 },
            // South wings flanking the single gate
            { minX: -5.7, maxX: -gateHalf + 0.15, minZ: 5.3, maxZ: 5.7 },
            { minX: gateHalf - 0.15, maxX: 5.7, minZ: 5.3, maxZ: 5.7 },
            // Cardboard box inside the pen
            { minX: -4.6, maxX: -2.6, minZ: -4.6, maxZ: -2.6 },
        ];
        this.circleColliders = [
            { x: 3.8, z: -3.6, r: 0.7 },
            { x: -gateHalf, z: 5.5, r: 0.35 },
            { x: gateHalf, z: 5.5, r: 0.35 },
        ];
    }

    public onWindowResize(): void {
        const dpr = Math.min(window.devicePixelRatio || 1, 2);
        this.width = this.container.clientWidth;
        this.height = this.container.clientHeight;
        this.canvas.width = Math.round(this.width * dpr);
        this.canvas.height = Math.round(this.height * dpr);
        this.ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
        this.ctx.imageSmoothingEnabled = false;

        const usableWidth = this.width;
        const span = MEADOW_RADIUS * 2;
        const scale = Math.min(usableWidth / span, this.height / (span * GROUND_TILT + 6));
        const pixel = Math.max(1, Math.round(scale * 0.11));

        this.originX = usableWidth / 2;
        // The title card floats at the top center; give the meadow comfortable breathing room below it.
        this.originY = this.width < 700 ? this.height * 0.64 : this.height / 2 + scale * 1.5;

        const snap = (value: number) => Math.round(value / pixel) * pixel;
        this.view = {
            scale,
            pixel,
            snap,
            project: (x, z, height = 0) => ({
                sx: this.originX + x * scale,
                sy: this.originY + (z * GROUND_TILT - height) * scale,
            }),
        };

        this.buildGroundLayer(dpr);
        this.buildProps();
    }

    /** Converts a client point to the ground plane. */
    public toGround(clientX: number, clientY: number): Vec {
        const rect = this.canvas.getBoundingClientRect();
        const { scale } = this.view;
        return {
            x: (clientX - rect.left - this.originX) / scale,
            z: (clientY - rect.top - this.originY) / (scale * GROUND_TILT),
        };
    }

    // MARK: - Drawing helpers

    private rect(ctx: CanvasRenderingContext2D, x1: number, y1: number, x2: number, y2: number, color: string): void {
        const { snap, pixel } = this.view;
        const left = snap(Math.min(x1, x2));
        const top = snap(Math.min(y1, y2));
        const w = Math.max(pixel, snap(Math.max(x1, x2)) - left);
        const h = Math.max(pixel, snap(Math.max(y1, y2)) - top);
        ctx.fillStyle = color;
        ctx.fillRect(left, top, w, h);
    }

    /** A block with a lit top face and a front face, snapped to the pixel grid. */
    private block(
        ctx: CanvasRenderingContext2D,
        x1: number, x2: number, z1: number, z2: number,
        y0: number, y1: number, top: string, front: string
    ): void {
        const a = this.view.project(x1, z1, y1);
        const b = this.view.project(x2, z2, y1);
        const c = this.view.project(x2, z2, y0);
        this.rect(ctx, a.sx, a.sy, b.sx, b.sy, top);
        this.rect(ctx, a.sx, b.sy, c.sx, c.sy, front);
    }

    private buildGroundLayer(dpr: number): void {
        const layer = document.createElement('canvas');
        layer.width = this.canvas.width;
        layer.height = this.canvas.height;
        const ctx = layer.getContext('2d');
        if (!ctx) return;
        ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
        ctx.imageSmoothingEnabled = false;

        const { project, pixel, scale } = this.view;

        ctx.fillStyle = COLORS.background;
        ctx.fillRect(0, 0, this.width, this.height);

        // Soft accent glow from the top centre, matching the app's Theme.listBackground.
        const glow = ctx.createRadialGradient(this.width / 2, 0, 0, this.width / 2, 0, 430);
        glow.addColorStop(0, 'rgba(14, 220, 213, 0.16)');
        glow.addColorStop(1, 'rgba(14, 220, 213, 0)');
        ctx.fillStyle = glow;
        ctx.fillRect(0, 0, this.width, this.height);

        // Sparse pixel dots inside the meadow.
        for (let x = -24; x <= 24; x += 2) {
            for (let z = -24; z <= 24; z += 2) {
                if (Math.hypot(x, z) > MEADOW_RADIUS - 1.5) continue;
                const p = project(x, z);
                this.rect(ctx, p.sx, p.sy, p.sx + pixel, p.sy + pixel, COLORS.dot);
            }
        }

        // The quiet meadow ring, like the iOS offline herd.
        const center = project(0, 0);
        ctx.strokeStyle = COLORS.border;
        ctx.lineWidth = Math.max(2, pixel * 2);
        ctx.beginPath();
        ctx.ellipse(center.sx, center.sy, MEADOW_RADIUS * scale, MEADOW_RADIUS * scale * GROUND_TILT, 0, 0, Math.PI * 2);
        ctx.stroke();

        // Corral pad.
        const nw = project(-5.5, -5.5);
        const se = project(5.5, 5.5);
        this.rect(ctx, nw.sx, nw.sy, se.sx, se.sy, COLORS.pad);

        // Gate threshold in the accent color.
        const gl = project(-2.2, 5.5);
        const gr = project(2.2, 5.5);
        this.rect(ctx, gl.sx, gl.sy, gr.sx, gl.sy + pixel, COLORS.accent);

        // Yarn balls.
        const yarn = [
            { x: -10, z: -6, color: '#0EDCD5' },
            { x: 11, z: 6, color: '#FFD60A' },
            { x: -6, z: 14, color: '#FF453A' },
            { x: 9, z: -10, color: '#8CBDFA' },
        ];
        yarn.forEach(({ x, z, color }) => {
            const p = project(x, z);
            const u = pixel;
            this.rect(ctx, p.sx - u, p.sy - 3 * u, p.sx + 2 * u, p.sy, color);
            this.rect(ctx, p.sx - 2 * u, p.sy - 2 * u, p.sx + 3 * u, p.sy - u, color);
            this.rect(ctx, p.sx, p.sy - 2 * u, p.sx + u, p.sy - u, 'rgba(0, 0, 0, 0.25)');
            this.rect(ctx, p.sx + 2 * u, p.sy, p.sx + 6 * u, p.sy + u, color);
        });

        this.groundLayer = layer;
    }

    private buildProps(): void {
        const props: Prop[] = [];
        const half = 5.5;
        const gateHalf = 2.4;
        const t = 0.1; // rail half-thickness
        const p = 0.19; // post half-width

        const post = (x: number, z: number, height = 1.6, lantern = false) => {
            props.push({
                z: z + p,
                draw: (ctx) => {
                    this.block(ctx, x - p, x + p, z - p, z + p, 0, height, COLORS.postTop, COLORS.post);
                    if (lantern) {
                        this.block(ctx, x - 0.12, x + 0.12, z - 0.12, z + 0.12, height, height + 0.3, COLORS.accent, COLORS.accent);
                    }
                },
            });
        };

        const railX = (x1: number, x2: number, z: number) => {
            props.push({
                z: z + t,
                draw: (ctx) => {
                    this.block(ctx, x1, x2, z - t, z + t, 0.4, 0.62, COLORS.railTop, COLORS.rail);
                    this.block(ctx, x1, x2, z - t, z + t, 1.0, 1.22, COLORS.railTop, COLORS.rail);
                },
            });
        };

        const railZ = (x: number, z1: number, z2: number) => {
            props.push({
                z: z2,
                draw: (ctx) => {
                    this.block(ctx, x - t, x + t, z1, z2, 0.4, 0.62, COLORS.railTop, COLORS.rail);
                    this.block(ctx, x - t, x + t, z1, z2, 1.0, 1.22, COLORS.railTop, COLORS.rail);
                },
            });
        };

        // North wall.
        railX(-half, half, -half);
        // Side walls, split into bays so cats sort against them.
        const bays = [-half, -2.75, 0, 2.75, half];
        for (let i = 0; i < bays.length - 1; i++) {
            railZ(-half, bays[i], bays[i + 1]);
            railZ(half, bays[i], bays[i + 1]);
        }
        // South wings around the gate.
        railX(-half, -gateHalf, half);
        railX(gateHalf, half, half);

        // Posts.
        [[-half, -half], [half, -half], [-half, half], [half, half]].forEach(([x, z]) => post(x, z, 1.6, true));
        [-2.75, 0, 2.75].forEach((v) => {
            post(v, -half);
            post(-half, v);
            post(half, v);
        });
        const wing = gateHalf + (half - gateHalf) / 2;
        post(-wing, half);
        post(wing, half);
        post(-gateHalf, half, 2.0, true);
        post(gateHalf, half, 2.0, true);

        // Gate beam and sign.
        props.push({
            z: half + 0.3,
            draw: (ctx) => {
                this.block(ctx, -gateHalf - 0.3, gateHalf + 0.3, half - 0.15, half + 0.15, 2.5, 2.8, COLORS.beam, COLORS.beam);
                this.block(ctx, -1.9, 1.9, half - 0.05, half + 0.05, 2.85, 3.55, COLORS.sign, COLORS.sign);
                const center = this.view.project(0, half + 0.05, 3.2);
                // Fit the text to the plate; skip it when it would be unreadably small.
                const size = Math.round(this.view.scale * 0.42);
                if (size < 7) return;
                ctx.fillStyle = COLORS.accent;
                ctx.font = `700 ${size}px ui-monospace, "SF Mono", Menlo, monospace`;
                ctx.textAlign = 'center';
                ctx.textBaseline = 'middle';
                ctx.fillText('HERDR CORRAL', Math.round(center.sx), Math.round(center.sy));
            },
        });

        // Cardboard box.
        props.push({
            z: -2.7,
            draw: (ctx) => {
                this.block(ctx, -4.6, -2.6, -4.5, -2.7, 0, 1.2, COLORS.boxTop, COLORS.box);
                this.block(ctx, -4.6, -2.6, -4.5, -4.2, 1.2, 1.55, COLORS.box, COLORS.box);
                this.block(ctx, -4.0, -3.2, -4.5, -2.7, 1.2, 1.22, COLORS.post, COLORS.post);
            },
        });

        // Scratching post with a toy.
        props.push({
            z: -2.9,
            draw: (ctx) => {
                this.block(ctx, 3.1, 4.5, -4.3, -2.9, 0, 0.15, COLORS.base, COLORS.base);
                for (let i = 0; i < 4; i++) {
                    const color = i % 2 === 0 ? COLORS.rope : COLORS.ropeShade;
                    this.block(ctx, 3.55, 4.05, -3.85, -3.35, 0.15 + i * 0.5, 0.65 + i * 0.5, COLORS.rope, color);
                }
                this.block(ctx, 3.6, 4.0, -3.8, -3.4, 2.15, 2.5, COLORS.accent, COLORS.accent);
            },
        });

        // Rocks out in the meadow.
        [
            { x: -14, z: 8, s: 1.2 }, { x: -16, z: -12, s: 1.8 }, { x: 12, z: -15, s: 1.5 },
            { x: 16, z: 10, s: 1.3 }, { x: 5, z: 18, s: 1.4 }, { x: -8, z: 17, s: 1.1 },
        ].forEach(({ x, z, s }) => {
            props.push({
                z: z + s * 0.5,
                draw: (ctx) => {
                    this.block(ctx, x - s, x + s, z - s * 0.5, z + s * 0.5, 0, s * 0.6, COLORS.rockTop, COLORS.rock);
                    this.block(ctx, x - s * 0.55, x + s * 0.45, z - s * 0.3, z + s * 0.2, s * 0.6, s * 0.95, COLORS.rockTop, COLORS.rock);
                },
            });
        });

        this.props = props;
    }

    // MARK: - Physics

    public resolveCollision(pos: Vec, vel: Vec, radius: number = 0.7): void {
        for (const box of this.fenceColliders) {
            const cx = Math.max(box.minX, Math.min(box.maxX, pos.x));
            const cz = Math.max(box.minZ, Math.min(box.maxZ, pos.z));
            const dx = pos.x - cx;
            const dz = pos.z - cz;
            const distSq = dx * dx + dz * dz;
            if (distSq >= radius * radius) continue;

            const dist = Math.sqrt(distSq);
            if (dist > 0.0001) {
                const overlap = radius - dist;
                const nx = dx / dist;
                const nz = dz / dist;
                pos.x += nx * overlap;
                pos.z += nz * overlap;
                const dot = vel.x * nx + vel.z * nz;
                if (dot < 0) {
                    vel.x -= dot * nx;
                    vel.z -= dot * nz;
                }
            } else {
                // Inside the collider: push out to the nearest edge.
                const dLeft = Math.abs(pos.x - box.minX);
                const dRight = Math.abs(box.maxX - pos.x);
                const dTop = Math.abs(pos.z - box.minZ);
                const dBottom = Math.abs(box.maxZ - pos.z);
                const minD = Math.min(dLeft, dRight, dTop, dBottom);
                if (minD === dLeft) {
                    pos.x = box.minX - radius;
                    if (vel.x > 0) vel.x = 0;
                } else if (minD === dRight) {
                    pos.x = box.maxX + radius;
                    if (vel.x < 0) vel.x = 0;
                } else if (minD === dTop) {
                    pos.z = box.minZ - radius;
                    if (vel.z > 0) vel.z = 0;
                } else {
                    pos.z = box.maxZ + radius;
                    if (vel.z < 0) vel.z = 0;
                }
            }
        }

        for (const circle of this.circleColliders) {
            const dx = pos.x - circle.x;
            const dz = pos.z - circle.z;
            const distSq = dx * dx + dz * dz;
            const minDist = circle.r + radius;
            if (distSq >= minDist * minDist || distSq <= 0.0001) continue;

            const dist = Math.sqrt(distSq);
            const overlap = minDist - dist;
            const nx = dx / dist;
            const nz = dz / dist;
            pos.x += nx * overlap;
            pos.z += nz * overlap;
            const dot = vel.x * nx + vel.z * nz;
            if (dot < 0) {
                vel.x -= dot * nx;
                vel.z -= dot * nz;
            }
        }
    }

    /** A cat is inside once it passes the South Gate threshold. */
    public isInsideFence(pos: Vec): boolean {
        return pos.x >= -4.8 && pos.x <= 4.8 && pos.z >= -4.8 && pos.z <= 5.1;
    }

    // MARK: - Rendering

    public render(cats: Cat[]): void {
        const ctx = this.ctx;
        if (this.groundLayer) {
            ctx.save();
            ctx.setTransform(1, 0, 0, 1, 0, 0);
            ctx.drawImage(this.groundLayer, 0, 0);
            ctx.restore();
        }

        const drawables: Prop[] = [
            ...this.props,
            ...cats.map((cat) => ({ z: cat.position.z, draw: (c: CanvasRenderingContext2D) => cat.draw(c, this.view) })),
        ];
        drawables.sort((a, b) => a.z - b.z);
        drawables.forEach((d) => d.draw(ctx));

        // Bubbles float above everything.
        cats.forEach((cat) => cat.drawBubble(ctx, this.view));
    }

    public destroy(): void {
        window.removeEventListener('resize', this.resizeHandler);
        this.canvas.remove();
    }
}
