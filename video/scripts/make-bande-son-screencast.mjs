// Bande-son du screencast (19 s, 30 fps) — MUSIQUE feutrée (DA Livret).
// Pas de clic de frappe : un petit bed musical chaud et posé, façon papier/éditorial.
// Pad doux + harpe feutrée sur une progression qui résout (Dm–Bb–C–F = vi–IV–V–I
// en fa majeur), souffle + note d'accent quand le ghost ROUGE se pose (~16 s),
// note de validation au Tab (~16,8 s). 100% synthétisé, zéro asset externe.
// Sortie : public/son-screencast.wav.

import {writeFileSync} from 'node:fs';
import {dirname, join} from 'node:path';
import {fileURLToPath} from 'node:url';

const ROOT = join(dirname(fileURLToPath(import.meta.url)), '..');
const OUT = join(ROOT, 'public', 'son-screencast.wav');
const SR = 44100;
const FPS = 30;
const DUR = 570 / FPS; // 19,0 s (capture souffleuse-bonjour, fin morte coupée)
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

/** Pluck chaud façon harpe (note feutrée, longue décroissance). */
function pluck(t, f, vel = 0.16, pan = 0.1) {
    const s0 = Math.round(t * SR);
    if (s0 < 0) return;
    const len = Math.min(Math.round(2.4 * SR), N - s0);
    const parts = [1, 0.4, 0.16];
    const gl = 0.5 * (1 - pan), gr = 0.5 * (1 + pan);
    for (let p = 0; p < parts.length; p++) {
        const fp = f * (p + 1) * (1 + 0.0006 * (p + 1) * (p + 1));
        if (fp > SR / 2 - 1000) break;
        const w = (2 * Math.PI * fp) / SR;
        const tp = 1.4 / (1 + 0.9 * p);
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

/** Pad chaud : accord soutenu (sinus + octave douce), attaque/relâche moelleux,
 *  léger vibrato. Le lit harmonique sous la harpe — discret, jamais devant. */
function pad(t, freqs, dur, vel = 0.05) {
    const s0 = Math.round(t * SR);
    if (s0 < 0) return;
    const len = Math.min(Math.round(dur * SR), N - s0);
    for (let v = 0; v < freqs.length; v++) {
        const fr = freqs[v];
        const w = (2 * Math.PI * fr) / SR;
        const pan = (v - 1) * 0.18; // étale l'accord dans le stéréo
        const gl = 0.5 * (1 - pan), gr = 0.5 * (1 + pan);
        for (let i = 0; i < len; i++) {
            const tt = i / SR;
            const atk = Math.min(1, tt / 0.5);
            const rel = Math.min(1, (dur - tt) / 0.7);
            const env = atk * Math.max(0, rel);
            const vib = 1 + 0.003 * Math.sin(2 * Math.PI * 4.6 * tt);
            const s = vel * env * (Math.sin(w * i * vib) + 0.28 * Math.sin(2 * w * i));
            L[s0 + i] += s * gl;
            R[s0 + i] += s * gr;
        }
    }
}

// Progression Dm – Bb – C – F (vi–IV–V–I en fa) : tension douce qui RÉSOUT sur
// fa (home) ~14,25 s, juste avant que le ghost se pose (~16 s) → sensation d'arrivée.
const BAR = 4.75; // s par accord (4 accords = 19 s)
const bars = [
    {pad: [146.83, 174.61, 220.0], arp: [293.66, 349.23, 440.0]}, // Dm
    {pad: [116.54, 146.83, 174.61], arp: [233.08, 293.66, 349.23]}, // Bb
    {pad: [130.81, 164.81, 196.0], arp: [261.63, 329.63, 392.0]}, // C
    {pad: [174.61, 220.0, 261.63], arp: [349.23, 440.0, 523.25]}, // F (résolution)
];
bars.forEach((b, k) => {
    const t0 = k * BAR;
    pad(t0, b.pad, BAR + 0.5, 0.05); // léger chevauchement = legato
    // Harpe : arpège clairsemé, posé (4 notes par accord), pan alternant.
    const arp = b.arp;
    pluck(t0 + 0.15, arp[0], 0.12, -0.15);
    pluck(t0 + 1.35, arp[1], 0.1, 0.12);
    pluck(t0 + 2.55, arp[2], 0.11, -0.1);
    pluck(t0 + 3.55, arp[1], 0.09, 0.16);
});

// Le ghost ROUGE se pose (~16 s) : souffle + note haute chaude (do).
souffle(15.85, 0.11);
pluck(16.0, 523.25, 0.15, 0.0);
// Tab : « application » accepté (~16,8 s) — note de validation (la), posée.
pluck(16.8, 440.0, 0.13, 0.08);

// Fondu d'ensemble : entrée douce (1,2 s) + sortie (2,0 s).
const fin = Math.round(1.2 * SR);
const fout = Math.round(2.0 * SR);
for (let i = 0; i < N; i++) {
    let g = 1;
    if (i < fin) g = i / fin;
    if (i > N - fout) g = Math.min(g, (N - i) / fout);
    L[i] *= g;
    R[i] *= g;
}

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
