// Bande-son du screencast (5 s, 30 fps, 150 frames) — version FEUTRÉE (DA Livret).
// Plus de clic mécanique brutal : des touches de frappe douces (corps grave,
// attaque molle, zéro transitoire dur), un souffle léger et une note chaude
// (pluck feutré) quand le ghost se pose. Synchronisé sur la compo Screencast
// (START_FROM=75 → on entre en fin de frappe de « Bonjour… »).
// Sortie : public/son-screencast.wav.

import {writeFileSync} from 'node:fs';
import {dirname, join} from 'node:path';
import {fileURLToPath} from 'node:url';

const ROOT = join(dirname(fileURLToPath(import.meta.url)), '..');
const OUT = join(ROOT, 'public', 'son-screencast.wav');
const SR = 44100;
const FPS = 30;
const DUR = 150 / FPS; // 5,0 s
const N = Math.round(SR * DUR);
const L = new Float64Array(N);
const R = new Float64Array(N);

function mulberry32(a) {
    return function () {
        a |= 0;
        a = (a + 0x6d2b79f5) | 0;
        let t = Math.imul(a ^ (a >>> 15), 1 | a);
        t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
        return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
    };
}
const rnd = mulberry32(0x50f7);

/**
 * Touche FEUTRÉE : corps grave (≈ deux sinus), attaque molle (pas de claquement),
 * une trace de bruit fortement passée-bas pour la matière (feutre/papier).
 * Rien d'agressif — c'est posé, pas claqué.
 */
function softTap(t, vel) {
    const s0 = Math.round(t * SR);
    if (s0 < 0) return;
    const len = Math.min(Math.round(0.08 * SR), N - s0);
    let lp = 0;
    for (let i = 0; i < len; i++) {
        const tt = i / SR;
        // attaque douce (montée ~4 ms) puis décroissance feutrée
        const env = (1 - Math.exp(-tt / 0.004)) * Math.exp(-tt / 0.05);
        const body = Math.sin(2 * Math.PI * 188 * tt) * 0.7 + Math.sin(2 * Math.PI * 94 * tt) * 0.3;
        // bruit très passé-bas (matière), discret
        const n = rnd() * 2 - 1;
        lp += 0.08 * (n - lp);
        const s = vel * env * (body + lp * 0.25);
        L[s0 + i] += s * 0.5;
        R[s0 + i] += s * 0.5;
    }
}

/** Souffle léger : bande de bruit dont le centre glisse (expiration douce). */
function souffle(t, vel = 0.12) {
    const s0 = Math.round(t * SR);
    if (s0 < 0) return;
    const dur = 0.9;
    const len = Math.min(Math.round(dur * SR), N - s0);
    let lpL = 0, bpL = 0, lpR = 0, bpR = 0;
    const q = 0.55;
    for (let i = 0; i < len; i++) {
        const x = i / SR / dur;
        const env = Math.pow(Math.sin(Math.PI * Math.min(1, x * 1.1)), 1.6);
        const fc = 420 + 1100 * Math.exp(-2.6 * x);
        const f = 2 * Math.sin((Math.PI * fc) / SR);
        const nL = rnd() * 2 - 1;
        const nR = rnd() * 2 - 1;
        lpL += f * bpL; bpL += f * (nL - lpL - q * bpL);
        lpR += f * bpR; bpR += f * (nR - lpR - q * bpR);
        L[s0 + i] += vel * env * bpL * 0.8;
        R[s0 + i] += vel * env * bpR * 0.8;
    }
}

/** Pluck chaud façon harpe (note posée quand le ghost arrive). */
function pluck(t, f, vel = 0.16, pan = 0.1) {
    const s0 = Math.round(t * SR);
    if (s0 < 0) return;
    const len = Math.min(Math.round(2.2 * SR), N - s0);
    const parts = [1, 0.4, 0.16];
    const gl = 0.5 * (1 - pan), gr = 0.5 * (1 + pan);
    for (let p = 0; p < parts.length; p++) {
        const fp = f * (p + 1) * (1 + 0.0006 * (p + 1) * (p + 1));
        if (fp > SR / 2 - 1000) break;
        const w = (2 * Math.PI * fp) / SR;
        const tp = 1.3 / (1 + 0.9 * p);
        const a = vel * parts[p] * 0.2;
        for (let i = 0; i < len; i++) {
            const tt = i / SR;
            const env = Math.min(1, tt / 0.01) * Math.exp(-tt / tp);
            const s = a * env * Math.sin(w * i + p * 1.7);
            L[s0 + i] += s * gl;
            R[s0 + i] += s * gr;
        }
    }
}

// Frappe restante : ~14 touches feutrées (comp ~frame 2 → 42, cadence humaine)
let cf = 2;
for (let k = 0; k < 14; k++) {
    softTap(cf / FPS, 0.34 + rnd() * 0.12);
    cf += 2.9 + rnd() * 0.7;
}
// Le ghost se pose : souffle léger + une note chaude (fa)
souffle(46 / FPS, 0.12);
pluck(50 / FPS, 349.23, 0.15);

// Encodage WAV PCM 16 bits stéréo (limiteur tanh doux)
const data = Buffer.alloc(N * 4);
for (let i = 0; i < N; i++) {
    const l = Math.tanh(L[i] * 0.9);
    const r = Math.tanh(R[i] * 0.9);
    data.writeInt16LE(Math.round(Math.max(-1, Math.min(1, l)) * 32767), i * 4);
    data.writeInt16LE(Math.round(Math.max(-1, Math.min(1, r)) * 32767), i * 4 + 2);
}
const h = Buffer.alloc(44);
h.write('RIFF', 0);
h.writeUInt32LE(36 + data.length, 4);
h.write('WAVEfmt ', 8);
h.writeUInt32LE(16, 16);
h.writeUInt16LE(1, 20);
h.writeUInt16LE(2, 22);
h.writeUInt32LE(SR, 24);
h.writeUInt32LE(SR * 4, 28);
h.writeUInt16LE(4, 32);
h.writeUInt16LE(16, 34);
h.write('data', 36);
h.writeUInt32LE(data.length, 40);
writeFileSync(OUT, Buffer.concat([h, data]));
console.log(`écrit : ${OUT} (${((44 + data.length) / 1e6).toFixed(1)} Mo, ${DUR}s)`);
