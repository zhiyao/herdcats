/**
 * Herdcats Audio Synthesizer
 * Uses Web Audio API for cozy retro synthesized kitty sounds.
 * Zero external audio files required.
 */

export class SoundSystem {
    private ctx: AudioContext | null = null;
    private muted: boolean = false;
    private initialized: boolean = false;

    constructor() {
        this.ctx = null;
        this.muted = false;
        this.initialized = false;
    }

    public init(): void {
        if (this.initialized || typeof window === 'undefined') return;
        try {
            const AudioContextClass = window.AudioContext || (window as unknown as { webkitAudioContext: typeof AudioContext }).webkitAudioContext;
            if (AudioContextClass) {
                this.ctx = new AudioContextClass();
                this.initialized = true;
            }
        } catch (e) {
            console.warn('Web Audio not supported', e);
        }
    }

    public resume(): void {
        this.init();
        if (this.ctx && this.ctx.state === 'suspended') {
            this.ctx.resume();
        }
    }

    public toggleMute(): boolean {
        this.muted = !this.muted;
        return this.muted;
    }

    public isMuted(): boolean {
        return this.muted;
    }

    // Playful meow sound with frequency sweep
    public meow(pitchMultiplier: number = 1.0): void {
        if (this.muted) return;
        this.resume();
        if (!this.ctx) return;

        const now = this.ctx.currentTime;
        const osc = this.ctx.createOscillator();
        const gain = this.ctx.createGain();

        osc.type = 'triangle';

        const baseFreq = 420 * pitchMultiplier;
        osc.frequency.setValueAtTime(baseFreq, now);
        osc.frequency.exponentialRampToValueAtTime(baseFreq * 1.8, now + 0.08);
        osc.frequency.exponentialRampToValueAtTime(baseFreq * 0.9, now + 0.35);

        gain.gain.setValueAtTime(0.001, now);
        gain.gain.linearRampToValueAtTime(0.2, now + 0.05);
        gain.gain.exponentialRampToValueAtTime(0.001, now + 0.38);

        osc.connect(gain);
        gain.connect(this.ctx.destination);

        osc.start(now);
        osc.stop(now + 0.4);
    }

    // Gentle purr effect
    public purr(): void {
        if (this.muted) return;
        this.resume();
        if (!this.ctx) return;

        const now = this.ctx.currentTime;
        const osc = this.ctx.createOscillator();
        const gain = this.ctx.createGain();

        osc.type = 'sawtooth';
        osc.frequency.setValueAtTime(45, now);

        gain.gain.setValueAtTime(0.01, now);
        gain.gain.linearRampToValueAtTime(0.08, now + 0.2);
        gain.gain.linearRampToValueAtTime(0.001, now + 0.6);

        osc.connect(gain);
        gain.connect(this.ctx.destination);

        osc.start(now);
        osc.stop(now + 0.6);
    }

    // Cat scurry footstep
    public step(): void {
        if (this.muted) return;
        this.resume();
        if (!this.ctx) return;

        const now = this.ctx.currentTime;
        const osc = this.ctx.createOscillator();
        const gain = this.ctx.createGain();

        osc.type = 'sine';
        osc.frequency.setValueAtTime(140, now);
        osc.frequency.exponentialRampToValueAtTime(60, now + 0.04);

        gain.gain.setValueAtTime(0.04, now);
        gain.gain.exponentialRampToValueAtTime(0.001, now + 0.04);

        osc.connect(gain);
        gain.connect(this.ctx.destination);

        osc.start(now);
        osc.stop(now + 0.05);
    }

    // Corral celebration chime (arpeggio)
    public corralChime(): void {
        if (this.muted) return;
        this.resume();
        if (!this.ctx) return;

        const notes = [523.25, 659.25, 783.99, 1046.50]; // C5, E5, G5, C6
        notes.forEach((freq, idx) => {
            if (!this.ctx) return;
            const now = this.ctx.currentTime + idx * 0.08;
            const osc = this.ctx.createOscillator();
            const gain = this.ctx.createGain();

            osc.type = 'sine';
            osc.frequency.setValueAtTime(freq, now);

            gain.gain.setValueAtTime(0.001, now);
            gain.gain.linearRampToValueAtTime(0.18, now + 0.02);
            gain.gain.exponentialRampToValueAtTime(0.001, now + 0.45);

            osc.connect(gain);
            gain.connect(this.ctx.destination);

            osc.start(now);
            osc.stop(now + 0.5);
        });
    }

    // Victory fanfare fanfare for all cats corralled
    public victoryFanfare(): void {
        if (this.muted) return;
        this.resume();
        if (!this.ctx) return;

        const melody = [
            { f: 523.25, d: 0.15, pause: 0.02 }, // C5
            { f: 659.25, d: 0.15, pause: 0.02 }, // E5
            { f: 783.99, d: 0.15, pause: 0.02 }, // G5
            { f: 1046.50, d: 0.35, pause: 0.05 }, // C6
            { f: 880.00, d: 0.15, pause: 0.02 }, // A5
            { f: 1046.50, d: 0.60, pause: 0.1 }  // C6 grand finish
        ];

        let cursor = this.ctx.currentTime + 0.05;
        melody.forEach(note => {
            if (!this.ctx) return;
            const osc = this.ctx.createOscillator();
            const gain = this.ctx.createGain();

            osc.type = 'triangle';
            osc.frequency.setValueAtTime(note.f, cursor);

            gain.gain.setValueAtTime(0.001, cursor);
            gain.gain.linearRampToValueAtTime(0.25, cursor + 0.03);
            gain.gain.exponentialRampToValueAtTime(0.001, cursor + note.d);

            osc.connect(gain);
            gain.connect(this.ctx.destination);

            osc.start(cursor);
            osc.stop(cursor + note.d);

            cursor += note.d + note.pause;
        });
    }
}

export const soundSystem = new SoundSystem();
