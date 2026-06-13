// Bande-son de « Le café bondé » (~30,2 s, 30 fps, 906 frames).
// L'arc sonore EST la thèse : le bruit, puis le silence.
//
//   0 → 12,0 s  (décor + duel) : brouhaha de café SYNTHÉTISÉ — murmure de
//                foule, voix marmonnées indistinctes, tintements de tasses,
//                un jet de machine. Tout est là, fort, encombrant.
//   12,0 s      (frame 360, début du souffle) : COUPURE NETTE du café
//                (fondu 0,35 s) → le silence. Entre alors la Gnossienne n° 1
//                d'Erik Satie (public/gnossienne.ogg, domaine public), nue.
//   12 → 30,2 s : Satie tient le calme. Un souffle (expiration filtrée) à
//                chaque apparition de ghost, une touche feutrée (pluck en fa
//                mineur, F→Ab→C) à chaque Tab. Fondu final.
//
// NE touche QUE public/bande-son-cafe.wav.
// Régénérer après tout recalage de Cafe.tsx (les timestamps ci-dessous sont
// dérivés du découpage T = {decor, duel, souffle, bilan} de la composition).

import {execFileSync} from 'node:child_process';
import {readFileSync, writeFileSync, unlinkSync} from 'node:fs';
import {dirname, join} from 'node:path';
import {fileURLToPath} from 'node:url';

const ROOT = join(dirname(fileURLToPath(import.meta.url)), '..');
const GNOSS = join(ROOT, 'public', 'gnossienne.ogg');
const TMP = '/tmp/bande-son-cafe-decode.wav';
const OUT = join(ROOT, 'public', 'bande-son-cafe.wav');

const SR = 44100;
const FPS = 30;
const DUR = 996 / FPS; // 33,2 s
const N = Math.round(SR * DUR);
const L = new Float64Array(N);
const R = new Float64Array(N);

// Bornes dérivées du découpage de Cafe.tsx (frame / 30)
const SOUFFLE_AT = 360 / FPS; // 12,0 s — la coupure
const END = DUR;
// Souffle = 3 phrases simulées. Mécanique : ghost 1 → Tab → ghost 2 → Tab.
// Repères dérivés des fenêtres de MontageApp : appStart = 360 + 16 + k*150 = 376 + 150k.
//   ghost 1 ≈ +44 · Tab 1 ≈ +82 · ghost 2 (régénéré) ≈ +90 · Tab 2 ≈ +120.
const GHOST1 = [0, 1, 2].map((k) => (376 + k * 150 + 44) / FPS);
const PRESS1 = [0, 1, 2].map((k) => (376 + k * 150 + 82) / FPS);
const GHOST2 = [0, 1, 2].map((k) => (376 + k * 150 + 90) / FPS);
const PRESS2 = [0, 1, 2].map((k) => (376 + k * 150 + 120) / FPS);
const DUEL_TAP = (96 + 150) / FPS; // 8,2 s — l'acceptation du panneau Souffleuse, dans le café

// PRNG déterministe (mulberry32) — reproductible, pas de Math.random non semé
function mulberry32(a) {
    return function () {
        a |= 0;
        a = (a + 0x6d2b79f5) | 0;
        let t = Math.imul(a ^ (a >>> 15), 1 | a);
        t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
        return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
    };
}
const rnd = mulberry32(0xca5e);

// ─── Le brouhaha de café ─────────────────────────────────────────────────────
function cafeBed() {
    const GAIN = 0.16;
    const bedEnd = Math.min(N, Math.round((SOUFFLE_AT + 0.45) * SR));
    // Murmure : deux bandes de bruit résonantes (une par canal, pour la largeur)
    let lpL = 0, bpL = 0, lpR = 0, bpR = 0;
    const q = 0.55;
    const fcMur = 480;
    const fMur = 2 * Math.sin((Math.PI * fcMur) / SR);
    // Voix marmonnées : 5 « parleurs » lointains, fondamentale voix + vibrato +
    // découpage syllabique, le tout passé en passe-bas → un marmonnement humain.
    const voices = Array.from({length: 5}, () => ({
        f0: 110 + rnd() * 150, // 110–260 Hz
        phase: rnd() * 6.283,
        vib: rnd() * 6.283,
        rate: 2.6 + rnd() * 2.6, // cadence syllabique 2,6–5,2 Hz
        gphase: rnd() * 6.283,
        gain: 0.5 + rnd() * 0.5,
        pan: rnd() * 2 - 1,
    }));
    let babLpL = 0, babLpR = 0;

    for (let i = 0; i < bedEnd; i++) {
        const t = i / SR;
        let env;
        if (t < 0.8) env = t / 0.8; // entrée douce
        else if (t < SOUFFLE_AT) env = 1; // le café occupe tout
        else env = Math.max(0, 1 - (t - SOUFFLE_AT) / 0.35); // COUPURE nette
        if (env <= 0) continue;
        // Houle de la foule : deux LFO lents qui se croisent
        const swell = 0.62 + 0.38 * (0.5 + 0.5 * Math.sin(2 * Math.PI * 0.13 * t)) * (0.5 + 0.5 * Math.sin(2 * Math.PI * 0.071 * t + 1.3));

        const nL = rnd() * 2 - 1;
        const nR = rnd() * 2 - 1;
        lpL += fMur * bpL; bpL += fMur * (nL - lpL - q * bpL);
        lpR += fMur * bpR; bpR += fMur * (nR - lpR - q * bpR);

        let bL = 0, bR = 0;
        for (const v of voices) {
            v.vib += (2 * Math.PI * 5.5) / SR;
            const pitch = v.f0 * (1 + 0.018 * Math.sin(v.vib));
            v.phase += (2 * Math.PI * pitch) / SR;
            let g = Math.sin(2 * Math.PI * v.rate * t + v.gphase);
            g = g > 0 ? g * g : 0; // portes syllabiques
            const s = Math.sin(v.phase) * g * v.gain;
            bL += s * (0.5 - v.pan * 0.45);
            bR += s * (0.5 + v.pan * 0.45);
        }
        // Passe-bas fort : le marmonnement reste inintelligible
        babLpL += 0.045 * (bL - babLpL);
        babLpR += 0.045 * (bR - babLpR);

        const g = env * swell * GAIN;
        L[i] += g * (bpL * 0.5 + babLpL * 1.1);
        R[i] += g * (bpR * 0.5 + babLpR * 1.1);
    }

    // Tintements de tasses/cuillères : transitoires clairs, dispersés
    const clinks = 8;
    for (let c = 0; c < clinks; c++) {
        const t = 0.6 + rnd() * (SOUFFLE_AT - 1.2);
        clink(t, 0.05 + rnd() * 0.05, rnd() * 2 - 1);
    }
    // Deux jets de machine à café (vapeur) : bruit passe-haut, enveloppe douce
    steam(3.4, 0.7);
    steam(7.9, 0.55);
}

function clink(t, vel, pan) {
    const s0 = Math.round(t * SR);
    const len = Math.min(Math.round(0.18 * SR), N - s0);
    if (s0 < 0) return;
    const f1 = 2400 + rnd() * 1400;
    const f2 = f1 * 2.01;
    const gl = 0.5 * (1 - pan), gr = 0.5 * (1 + pan);
    for (let i = 0; i < len; i++) {
        const tt = i / SR;
        const env = Math.exp(-tt / 0.045);
        const s = vel * env * (Math.sin(2 * Math.PI * f1 * tt) * 0.7 + Math.sin(2 * Math.PI * f2 * tt) * 0.3);
        L[s0 + i] += s * gl;
        R[s0 + i] += s * gr;
    }
}

function steam(t, vel) {
    const s0 = Math.round(t * SR);
    const dur = 0.6;
    const len = Math.min(Math.round(dur * SR), N - s0);
    if (s0 < 0) return;
    let hp = 0, last = 0;
    for (let i = 0; i < len; i++) {
        const x = i / SR / dur;
        const env = Math.pow(Math.sin(Math.PI * x), 1.6) * vel * 0.5;
        const n = rnd() * 2 - 1;
        hp = 0.85 * (hp + n - last); // passe-haut grossier → sifflement
        last = n;
        L[s0 + i] += hp * env * 0.5;
        R[s0 + i] += hp * env * 0.5;
    }
}

// ─── Le souffle : expiration filtrée (repris de la rafale, plus doux) ─────────
function souffle(t, vel = 0.22) {
    const s0 = Math.round(t * SR);
    const dur = 0.85;
    const len = Math.min(Math.round(dur * SR), N - s0);
    if (s0 < 0) return;
    let lpL = 0, bpL = 0, lpR = 0, bpR = 0;
    const q = 0.5;
    for (let i = 0; i < len; i++) {
        const x = i / SR / dur;
        const env = Math.pow(Math.sin(Math.PI * Math.min(1, x * 1.12)), 1.4);
        const fc = 450 + 1350 * Math.exp(-2.4 * x);
        const f = 2 * Math.sin((Math.PI * fc) / SR);
        const nL = rnd() * 2 - 1;
        const nR = rnd() * 2 - 1;
        lpL += f * bpL; bpL += f * (nL - lpL - q * bpL);
        lpR += f * bpR; bpR += f * (nR - lpR - q * bpR);
        L[s0 + i] += vel * env * bpL * 0.8;
        R[s0 + i] += vel * env * bpR * 0.8;
    }
}

// ─── La touche feutrée : un pluck doux (fa mineur) à chaque Tab ───────────────
function pluck(t, f, vel = 0.3, pan = 0.15) {
    const s0 = Math.round(t * SR);
    if (s0 < 0) return;
    const len = Math.min(Math.round(2.4 * SR), N - s0);
    const parts = [1, 0.4, 0.18, 0.08];
    const gl = 0.5 * (1 - pan), gr = 0.5 * (1 + pan);
    for (let p = 0; p < parts.length; p++) {
        const fp = f * (p + 1) * (1 + 0.0006 * (p + 1) * (p + 1));
        if (fp > SR / 2 - 1000) break;
        const w = (2 * Math.PI * fp) / SR;
        const tp = 1.2 / (1 + 0.9 * p);
        const a = vel * parts[p] * 0.2;
        for (let i = 0; i < len; i++) {
            const tt = i / SR;
            const env = Math.min(1, tt / 0.006) * Math.exp(-tt / tp);
            const s = a * env * Math.sin(w * i + p * 1.7);
            L[s0 + i] += s * gl;
            R[s0 + i] += s * gr;
        }
    }
}
function tap(t, f, vel) {
    // Petit choc feutré (corps grave très court) + le pluck qui chante.
    const s0 = Math.round(t * SR);
    if (s0 >= 0) {
        const len = Math.min(Math.round(0.12 * SR), N - s0);
        for (let i = 0; i < len; i++) {
            const tt = i / SR;
            const body = Math.exp(-tt / 0.03) * Math.sin(2 * Math.PI * 120 * tt);
            L[s0 + i] += vel * 0.25 * body * 0.5;
            R[s0 + i] += vel * 0.25 * body * 0.5;
        }
    }
    pluck(t + 0.01, f, vel);
}

// ─── La Gnossienne : décodée et posée à la coupure ───────────────────────────
function gnossienne() {
    const GAIN = 0.5;
    const AT = SOUFFLE_AT + 0.15; // entre juste après la coupure
    const take = END - AT + 0.5;
    execFileSync('npx', [
        'remotion', 'ffmpeg', '-hide_banner', '-loglevel', 'error',
        '-i', GNOSS, '-t', String(take), '-ac', '2', '-ar', String(SR),
        TMP, '-y',
    ], {cwd: ROOT, stdio: 'inherit'});
    const wav = readFileSync(TMP);
    const dataAt = 44;
    const frames = Math.floor((wav.length - dataAt) / 4);
    const t0 = Math.round(AT * SR);
    for (let i = 0; i < frames && t0 + i < N; i++) {
        const t = (t0 + i) / SR;
        const fin = Math.min(1, (t - AT) / 1.1); // fondu d'entrée 1,1 s
        const fout = t > END - 1.2 ? Math.cos(((t - (END - 1.2)) / 1.2) * Math.PI * 0.5) ** 2 : 1;
        const g = GAIN * fin * fout;
        const l = wav.readInt16LE(dataAt + i * 4) / 32768;
        const r = wav.readInt16LE(dataAt + i * 4 + 2) / 32768;
        L[t0 + i] += l * g;
        R[t0 + i] += r * g;
    }
    unlinkSync(TMP);
}

// ─── Assemblage ──────────────────────────────────────────────────────────────
const Hz = {F4: 349.23, Ab4: 415.30, C5: 523.25, Eb5: 622.25};

cafeBed();
gnossienne();

// Dans le café : une touche discrète quand le panneau Souffleuse accepte (duel)
tap(DUEL_TAP, Hz.F4, 0.16);

// Au souffle, par phrase : expiration (ghost 1) → touche (Tab 1) → expiration
// plus légère (ghost 2 régénéré) → touche (Tab 2). Paires montantes fa-mineur.
souffle(GHOST1[0], 0.20); tap(PRESS1[0], Hz.F4, 0.28); souffle(GHOST2[0], 0.15); tap(PRESS2[0], Hz.Ab4, 0.30);
souffle(GHOST1[1], 0.20); tap(PRESS1[1], Hz.Ab4, 0.30); souffle(GHOST2[1], 0.15); tap(PRESS2[1], Hz.C5, 0.32);
souffle(GHOST1[2], 0.20); tap(PRESS1[2], Hz.C5, 0.32); souffle(GHOST2[2], 0.15); tap(PRESS2[2], Hz.Eb5, 0.34);

// ─── Encodage WAV PCM 16 bits stéréo (limiteur tanh doux) ────────────────────
const data = Buffer.alloc(N * 4);
for (let i = 0; i < N; i++) {
    const l = Math.tanh(L[i]);
    const r = Math.tanh(R[i]);
    data.writeInt16LE(Math.round(Math.max(-1, Math.min(1, l)) * 32767), i * 4);
    data.writeInt16LE(Math.round(Math.max(-1, Math.min(1, r)) * 32767), i * 4 + 2);
}
const header = Buffer.alloc(44);
header.write('RIFF', 0);
header.writeUInt32LE(36 + data.length, 4);
header.write('WAVEfmt ', 8);
header.writeUInt32LE(16, 16);
header.writeUInt16LE(1, 20);
header.writeUInt16LE(2, 22);
header.writeUInt32LE(SR, 24);
header.writeUInt32LE(SR * 4, 28);
header.writeUInt16LE(4, 32);
header.writeUInt16LE(16, 34);
header.write('data', 36);
header.writeUInt32LE(data.length, 40);
writeFileSync(OUT, Buffer.concat([header, data]));
console.log(`écrit : ${OUT} (${((44 + data.length) / 1e6).toFixed(1)} Mo, ${DUR.toFixed(1)}s)`);
