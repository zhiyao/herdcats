/**
 * Pixel-art meadow cats for Herdcats.
 * Sprites follow the iOS empty states (`OfflineHerdView`, `LazyCatLoadingView`):
 * side-on blocks on a whole-pixel grid, with stepped paws and a hooked tail.
 */

import { soundSystem } from './audio';
import type { Vec, View, World } from './world';

export interface CatTheme {
    name: string;
    kind: string;
    fur: number;
    light: number;
    shade: number;
    collar: number;
    eyes: number;
}

export const CAT_THEMES: CatTheme[] = [
    { name: "Pixel", kind: "Tabby", fur: 0xC7A37A, light: 0xF2D4A6, shade: 0x87664D, collar: 0x0EDCD5, eyes: 0x2A7E43 },
    { name: "Claude", kind: "Anthropic", fur: 0xD97857, light: 0xF8E2D4, shade: 0x9E4B33, collar: 0xD97857, eyes: 0x4A3022 },
    { name: "Cursor", kind: "Electric", fur: 0x8CBDFA, light: 0xE8F3FF, shade: 0x558EC7, collar: 0x0EDCD5, eyes: 0x00EAB3 },
    { name: "Codex", kind: "Emerald", fur: 0x17A382, light: 0xD1FFFA, shade: 0x0F6E58, collar: 0x34C759, eyes: 0xFFD60A },
    { name: "Gemini", kind: "Amethyst", fur: 0x8F76B2, light: 0xF0EBF8, shade: 0x614C82, collar: 0x8F76B2, eyes: 0x38BDF8 },
    { name: "Copilot", kind: "Indigo", fur: 0x738CF2, light: 0xDEE5FF, shade: 0x4C65CE, collar: 0x738CF2, eyes: 0x0DB1C5 },
    { name: "Tuxedo", kind: "Midnight", fur: 0x1E1E2B, light: 0xFFFFFF, shade: 0x111119, collar: 0xFF453A, eyes: 0x34C759 },
    { name: "Ziggy", kind: "Golden", fur: 0xFFD60A, light: 0xFFF7CC, shade: 0xD4AD00, collar: 0x0EDCD5, eyes: 0x17A382 },
    { name: "Mochi", kind: "Snow", fur: 0xF5F6FA, light: 0xFFFFFF, shade: 0xD0D3E3, collar: 0xD9877D, eyes: 0x8CBDFA },
    { name: "Byte", kind: "Charcoal", fur: 0x3A3A52, light: 0x8E8E93, shade: 0x242433, collar: 0x30B0C7, eyes: 0xFFD60A }
];

export const CAT_STATES = {
    WANDER: 'wander',
    IDLE: 'idle',
    LOAF: 'loaf',
    GROOM: 'groom',
    SLEEP: 'sleep',
    ZOOMIES: 'zoomies',
    HERDED: 'herded',
    CORRALLED: 'corralled'
} as const;

export type CatStateType = typeof CAT_STATES[keyof typeof CAT_STATES];

export class Cat {
    public theme: CatTheme;
    public name: string;

    // Position & Physics
    public position: Vec;
    public velocity: Vec;
    public targetPoint: Vec;
    public heading: number;
    public facing: 1 | -1;

    // Status
    public state: CatStateType;
    public corralled: boolean = false;
    public stateTimer: number;
    public animTime: number;
    public speed: number;

    // Speech bubble
    public bubbleText: string = '';
    public bubbleTimer: number = 0;

    // Pointer reaction: rolled once per approach so a cat either flees or ignores you
    private noticedPointer: boolean = false;
    private ignoringPointer: boolean = false;

    private colors: { fur: string; light: string; shade: string; collar: string; eyes: string };

    constructor(theme: CatTheme, startX: number = 0, startZ: number = 0) {
        this.theme = theme;
        this.name = theme.name;

        this.position = { x: startX, z: startZ };
        this.velocity = { x: 0, z: 0 };
        this.targetPoint = { x: startX, z: startZ };
        this.heading = Math.random() * Math.PI * 2;
        this.facing = Math.sin(this.heading) < 0 ? -1 : 1;

        this.state = CAT_STATES.IDLE;
        this.corralled = false;
        this.stateTimer = 1 + Math.random() * 2;
        this.animTime = Math.random() * 10;
        this.speed = 0.04 + Math.random() * 0.02;

        const hex = (value: number) => `#${value.toString(16).padStart(6, '0')}`;
        this.colors = {
            fur: hex(theme.fur),
            light: hex(theme.light),
            shade: hex(theme.shade),
            collar: hex(theme.collar),
            eyes: hex(theme.eyes),
        };

        this.pickNewTarget();
    }

    public showBubble(text: string, duration: number = 2.0): void {
        this.bubbleText = text;
        this.bubbleTimer = duration;
    }

    public pickNewTarget(): void {
        if (this.corralled) {
            // Inside the fence pen (strictly safe zone [-3.6, 3.6])
            this.targetPoint = {
                x: (Math.random() - 0.5) * 7.2,
                z: (Math.random() - 0.5) * 7.2
            };
        } else {
            // Outside in the meadow: local, independent wandering!
            // Cats explore their local territory and naturally avoid the center fence.
            let attempts = 0;
            let targetFound = false;

            while (attempts < 12 && !targetFound) {
                attempts++;
                // Pick a local wander offset (3.5 to 8.5 units from current position)
                const wanderAngle = Math.random() * Math.PI * 2;
                const wanderDist = 3.5 + Math.random() * 5.0;
                let candX = this.position.x + Math.cos(wanderAngle) * wanderDist;
                let candZ = this.position.z + Math.sin(wanderAngle) * wanderDist;

                // Clamp to meadow boundaries [-20, 20]
                candX = Math.max(-20, Math.min(20, candX));
                candZ = Math.max(-20, Math.min(20, candZ));

                // Natural fence buffer: independent cats avoid the center fence corral (radius ~7.8)
                const distFromCenter = Math.hypot(candX, candZ);
                if (distFromCenter >= 7.8) {
                    this.targetPoint = { x: candX, z: candZ };
                    targetFound = true;
                }
            }

            if (!targetFound) {
                // If cat was near the center, push wander target outward into the meadow
                const currentAngle = Math.atan2(this.position.z, this.position.x);
                const safeDist = 10.0 + Math.random() * 6.0;
                this.targetPoint = {
                    x: Math.cos(currentAngle) * safeDist,
                    z: Math.sin(currentAngle) * safeDist
                };
            }
        }
    }

    public applyHerdingForce(mouseX: number, mouseZ: number, strength: number = 1.0): void {
        if (this.corralled) return;

        const awayX = this.position.x - mouseX;
        const awayZ = this.position.z - mouseZ;
        const distFromMouse = Math.hypot(awayX, awayZ);

        // Tactile influence radius: cursor must be near cat to spook it
        const maxInfluenceRadius = 2.8;
        if (distFromMouse > maxInfluenceRadius || distFromMouse < 0.001) {
            this.noticedPointer = false;
            return;
        }

        // Cats are cats: on each new approach, some simply can't be bothered.
        if (!this.noticedPointer) {
            this.noticedPointer = true;
            const aloofChance = this.state === CAT_STATES.SLEEP || this.state === CAT_STATES.LOAF ? 0.5 : 0.25;
            this.ignoringPointer = Math.random() < aloofChance;
            if (this.ignoringPointer && Math.random() < 0.5) {
                const snubs = ["😼", "...", "meh", "😾"];
                this.showBubble(snubs[Math.floor(Math.random() * snubs.length)], 1.2);
            }
        }
        if (this.ignoringPointer) return;

        // Flee strictly away from the pointer
        const dirX = awayX / distFromMouse;
        const dirZ = awayZ / distFromMouse;
        const proximity = (maxInfluenceRadius - distFromMouse) / maxInfluenceRadius;
        const pushSpeed = Math.min(0.38, (0.09 + proximity * 0.26) * strength);

        this.velocity.x += dirX * pushSpeed;
        this.velocity.z += dirZ * pushSpeed;
        this.heading = Math.atan2(dirX, dirZ);

        // Brief burst only while the cursor is close
        this.state = CAT_STATES.HERDED;
        this.stateTimer = 0.45;

        if (Math.random() < 0.15) {
            soundSystem.step();
        }

        if (Math.random() < 0.1) {
            const reactions = ["🐾", "💨", "!", "mrow~"];
            this.showBubble(reactions[Math.floor(Math.random() * reactions.length)], 1.0);
        }
    }

    public steerTowardTarget(): void {
        const dx = this.targetPoint.x - this.position.x;
        const dz = this.targetPoint.z - this.position.z;
        const dist = Math.hypot(dx, dz);

        if (dist < 1.2) {
            this.pickNewTarget();
            return;
        }

        let desiredHeading = Math.atan2(dx, dz);
        let turnRate = 0.06;

        // If uncorralled and wandering close to the center fence, steer outward into the meadow!
        if (!this.corralled) {
            const distFromOrigin = Math.hypot(this.position.x, this.position.z);
            if (distFromOrigin < 8.5) {
                desiredHeading = Math.atan2(this.position.x, this.position.z);
                turnRate = 0.15;
            }
        }

        let diff = desiredHeading - this.heading;
        while (diff < -Math.PI) diff += Math.PI * 2;
        while (diff > Math.PI) diff -= Math.PI * 2;
        this.heading += diff * turnRate;
    }

    public avoidOtherCats(cats: Cat[]): void {
        cats.forEach(other => {
            if (other === this) return;
            const dx = this.position.x - other.position.x;
            const dz = this.position.z - other.position.z;
            const dist = Math.hypot(dx, dz);
            const minDist = 1.4;

            if (dist < minDist && dist > 0.01) {
                const push = (minDist - dist) * 0.03;
                this.velocity.x += (dx / dist) * push;
                this.velocity.z += (dz / dist) * push;

                if (Math.random() < 0.003 && !this.corralled && !other.corralled) {
                    this.showBubble("🐾", 1.5);
                }
            }
        });
    }

    public chooseNewState(): void {
        const roll = Math.random();

        if (this.corralled) {
            if (roll < 0.4) {
                this.state = CAT_STATES.LOAF;
                this.stateTimer = 4 + Math.random() * 6;
                if (Math.random() < 0.3) this.showBubble("purr~", 2);
            } else if (roll < 0.7) {
                this.state = CAT_STATES.SLEEP;
                this.stateTimer = 5 + Math.random() * 8;
                this.showBubble("💤", 2.5);
            } else {
                this.state = CAT_STATES.WANDER;
                this.stateTimer = 2 + Math.random() * 4;
                this.pickNewTarget();
            }
            return;
        }

        // Out in the wild
        if (roll < 0.45) {
            this.state = CAT_STATES.WANDER;
            this.stateTimer = 3 + Math.random() * 5;
            this.pickNewTarget();
        } else if (roll < 0.65) {
            this.state = CAT_STATES.IDLE;
            this.stateTimer = 2 + Math.random() * 3;
        } else if (roll < 0.8) {
            this.state = CAT_STATES.LOAF;
            this.stateTimer = 4 + Math.random() * 5;
        } else if (roll < 0.92) {
            this.state = CAT_STATES.GROOM;
            this.stateTimer = 3 + Math.random() * 3;
            if (Math.random() < 0.3) this.showBubble("👅", 1.8);
        } else {
            this.state = CAT_STATES.ZOOMIES;
            this.stateTimer = 2 + Math.random() * 3;
            this.pickNewTarget();
            this.showBubble("⚡", 1.5);
        }
    }

    public markCorralled(): void {
        if (this.corralled) return;
        this.corralled = true;
        this.state = CAT_STATES.LOAF;
        this.stateTimer = 4 + Math.random() * 4;

        this.velocity = { x: 0, z: 0 };

        // Settle cat firmly in the interior safe zone
        if (this.position.z > 4.2) {
            this.position.z = 4.0;
        }

        soundSystem.corralChime();

        const corralEmojis = ["❤️", "✨", "Purr!", "😸", "Meow!"];
        this.showBubble(corralEmojis[Math.floor(Math.random() * corralEmojis.length)], 2.5);
    }

    public enforceBoundaries(): void {
        if (this.corralled) {
            const penLimit = 4.6;
            if (this.position.x > penLimit) { this.position.x = penLimit; this.velocity.x = 0; }
            if (this.position.x < -penLimit) { this.position.x = -penLimit; this.velocity.x = 0; }
            if (this.position.z > penLimit) { this.position.z = penLimit; this.velocity.z = 0; }
            if (this.position.z < -penLimit) { this.position.z = -penLimit; this.velocity.z = 0; }
        } else {
            const limit = 22.0;
            if (this.position.x > limit) { this.position.x = limit; this.velocity.x *= -0.5; }
            if (this.position.x < -limit) { this.position.x = -limit; this.velocity.x *= -0.5; }
            if (this.position.z > limit) { this.position.z = limit; this.velocity.z *= -0.5; }
            if (this.position.z < -limit) { this.position.z = -limit; this.velocity.z *= -0.5; }
        }
    }

    public update(delta: number, cats: Cat[], world: World): void {
        this.animTime += delta;
        this.stateTimer -= delta;

        if (this.bubbleTimer > 0) {
            this.bubbleTimer -= delta;
        }

        if (this.stateTimer <= 0 && this.state !== CAT_STATES.HERDED) {
            this.chooseNewState();
        }

        this.avoidOtherCats(cats);

        let moveSpeed = 0;
        switch (this.state) {
            case CAT_STATES.WANDER:
                moveSpeed = this.speed;
                this.steerTowardTarget();
                break;
            case CAT_STATES.ZOOMIES:
                moveSpeed = this.speed * 2.6;
                this.steerTowardTarget();
                break;
            case CAT_STATES.HERDED:
                // Keep running along the flee heading set by applyHerdingForce
                moveSpeed = this.speed * 2.4;
                if (this.stateTimer <= 0) {
                    this.state = CAT_STATES.WANDER;
                    this.pickNewTarget();
                }
                break;
            case CAT_STATES.LOAF:
            case CAT_STATES.SLEEP:
            case CAT_STATES.GROOM:
            case CAT_STATES.IDLE:
                moveSpeed = 0;
                break;
        }

        if (moveSpeed > 0) {
            this.velocity.x += Math.sin(this.heading) * moveSpeed * 0.4;
            this.velocity.z += Math.cos(this.heading) * moveSpeed * 0.4;
        }

        this.position.x += this.velocity.x;
        this.position.z += this.velocity.z;
        this.velocity.x *= 0.85;
        this.velocity.z *= 0.85;

        world.resolveCollision(this.position, this.velocity, 0.75);

        if (!this.corralled && world.isInsideFence(this.position)) {
            this.markCorralled();
        }

        this.enforceBoundaries();

        // Side-on sprites only face left or right; keep the last side while mostly vertical.
        const sideways = Math.sin(this.heading);
        if (Math.abs(sideways) > 0.2) {
            this.facing = sideways < 0 ? -1 : 1;
        }
    }

    public isMoving(): boolean {
        return Math.hypot(this.velocity.x, this.velocity.z) > 0.01;
    }

    /** Draws the cat with its feet on the ground point, in whole sprite pixels. */
    public draw(ctx: CanvasRenderingContext2D, view: View): void {
        const { sx, sy } = view.project(this.position.x, this.position.z);
        const u = view.pixel;
        const ox = view.snap(sx);
        const oy = view.snap(sy);
        const facing = this.facing;
        const { fur, light, shade, collar, eyes } = this.colors;
        const pink = '#D9877D';
        const ink = '#332E2E';

        // Sprite grid: x spans -15..8 facing right, y = 7 is the ground.
        const block = (x: number, y: number, w: number, h: number, color: string) => {
            const gx = facing > 0 ? x : -(x + w);
            ctx.fillStyle = color;
            // Shift so the sprite's centre (x = -3.5) sits on the ground point.
            ctx.fillRect(ox + (gx + (facing > 0 ? 3 : -4)) * u, oy + (y - 7) * u, w * u, h * u);
        };

        block(-11, 7, 19, 1, 'rgba(0, 0, 0, 0.35)');

        const resting = this.state === CAT_STATES.LOAF || this.state === CAT_STATES.SLEEP;
        if (resting) {
            const breathe = Math.floor(this.animTime * 1.2) % 2;
            const sway = Math.floor(this.animTime * 1.5) % 2;
            // Tail wraps along the ground.
            block(-15, 5 - sway, 6, 2, fur);
            block(-15, 5 - sway, 2, 2, shade);
            block(-11, 1 - breathe, 15, 6 + breathe, fur);
            block(-8, 1 - breathe, 2, 3, shade);
            block(-4, 1 - breathe, 2, 3, shade);
            block(1, -3, 7, 9, fur);
            block(1, -6, 2, 4, fur);
            block(6, -6, 2, 4, fur);
            block(2, -5, 1, 2, pink);
            block(6, -5, 1, 2, pink);
            block(1, 2, 1, 3, collar);
            block(5, 2, 3, 2, light);
            block(7, 2, 1, 1, pink);
            block(2, 6, 5, 1, light);
            if (this.state === CAT_STATES.SLEEP) {
                block(4, -1, 2, 1, ink);
            } else {
                block(5, -1, 1, 2, eyes);
            }
            return;
        }

        const running = this.state === CAT_STATES.ZOOMIES || this.state === CAT_STATES.HERDED;
        const moving = this.isMoving();
        const step = moving ? Math.floor(this.animTime * (running ? 12 : 6)) % 4 : 0;
        const reach = running ? 2 : 1;
        const stride = [0, reach, 0, -reach][step];
        const bounce = running && step % 2 === 1 ? 1 : 0;
        const sway = Math.floor(this.animTime * (moving ? 4 : 1.5)) % 2;
        const groomDip = this.state === CAT_STATES.GROOM && Math.floor(this.animTime * 3) % 2 === 0 ? 2 : 0;
        const b = -bounce;

        // Far paws move opposite the near paws.
        block(-7 + stride, 3, 2, 4, shade);
        block(3 - stride, 3, 2, 4, shade);
        // Upright hooked tail.
        block(-13, -7 + b, 2, 7, fur);
        block(-15 + sway, -8 + b, 4, 2, fur);
        block(-15 + sway, -8 + b, 2, 2, shade);
        // Body, belly, and tabby stripes.
        block(-11, -2 + b, 15, 6, fur);
        block(-9, 2 + b, 11, 2, light);
        block(-8, -2 + b, 2, 3, shade);
        block(-4, -2 + b, 2, 3, shade);
        // Head, square ears, collar.
        const hy = b + groomDip;
        block(1, -6 + hy, 7, 8, fur);
        block(1, -9 + hy, 2, 4, fur);
        block(6, -9 + hy, 2, 4, fur);
        block(2, -8 + hy, 1, 2, pink);
        block(6, -8 + hy, 1, 2, pink);
        block(1, -1 + b, 1, 4, collar);
        block(5, -1 + hy, 3, 2, light);
        block(7, -1 + hy, 1, 1, pink);
        if (groomDip) {
            block(5, -4 + hy, 2, 1, ink);
        } else {
            block(5, -4 + hy, 1, 2, eyes);
        }
        // Near paws with light socks.
        block(-9 - stride, 3, 3, 4, fur);
        block(-9 - stride, 6, 3, 1, light);
        block(1 + stride, 3, 3, 4, fur);
        block(1 + stride, 6, 3, 1, light);
    }

    public drawBubble(ctx: CanvasRenderingContext2D, view: View): void {
        if (this.bubbleTimer <= 0 || !this.bubbleText) return;
        const { sx, sy } = view.project(this.position.x, this.position.z);
        const u = view.pixel;
        const size = Math.max(11, Math.round(view.scale * 0.55));

        ctx.font = `700 ${size}px -apple-system, BlinkMacSystemFont, "SF Pro Text", sans-serif`;
        const width = Math.ceil(ctx.measureText(this.bubbleText).width) + size;
        const height = size + Math.round(size * 0.7);
        const x = Math.round(sx - width / 2);
        const y = Math.round(sy - 18 * u - height - 4);

        ctx.fillStyle = 'rgba(31, 31, 46, 0.92)';
        ctx.strokeStyle = '#0EDCD5';
        ctx.lineWidth = 2;
        ctx.beginPath();
        ctx.roundRect(x, y, width, height, height / 2);
        ctx.fill();
        ctx.stroke();

        ctx.fillStyle = '#FFFFFF';
        ctx.textAlign = 'center';
        ctx.textBaseline = 'middle';
        ctx.fillText(this.bubbleText, Math.round(sx), y + height / 2 + 1);
    }
}
