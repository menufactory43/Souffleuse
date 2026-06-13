// Bande-son de « La rafale de Tab » (~15 s, 30 fps, 450 frames) :
// base = valse-minute.flac (Ré bémol majeur, domaine public Musopen)
// Trois coups de tampon (choc mat + accord plaqué) calés sur les 3 Tab,
// une expiration (bande résonante glissante) à chaque ghost.
// Montée I→IV→V en Db majeur : Db → Gb → Ab (même contour que PRESETS.rapide).
//
// Timestamps exacts (frame / 30) :
//   Ghost 1 : frame 56  → 1.87 s   Tab 1 : frame  88 →  2.93 s
//   Ghost 2 : frame 176 → 5.87 s   Tab 2 : frame 208 →  6.93 s
//   Ghost 3 : frame 306 → 10.20 s  Tab 3 : frame 334 → 11.13 s
//   Boucle audio douce : fondu de sortie raccordé au début.
//
// NE PAS écraser public/bande-son.wav (la bande-son de la composition 16:9).

import {execFileSync} from 'node:child_process';
import {readFileSync, writeFileSync, unlinkSync} from 'node:fs';
import {dirname, join} from 'node:path';
import {fileURLToPath} from 'node:url';

const ROOT = join(dirname(fileURLToPath(import.meta.url)), '..');
// Base musicale : valse-minute.flac — même que PRESETS.rapide, Db majeur
const SRC  = join(ROOT, 'public', 'valse-minute.flac');
const TMP  = '/tmp/bande-son-rafale-decode.wav';
// Sortie dédiée — public/bande-son.wav N'EST PAS touché
const OUT  = join(ROOT, 'public', 'bande-son-rafale.wav');

const SR = 44100;
const DUR = 15.0;
// Musique dès 0.3 s : hook immédiat, pas d'intro silencieuse
const MUSIC_AT = 0.3;
const N  = Math.round(SR * DUR);
const L  = new Float64Array(N);
const R  = new Float64Array(N);

// Gain de la valse-minute : même réglage que PRESETS.rapide
const GAIN = 0.85;

// Décodage via le ffmpeg embarqué de Remotion (0 dépendance système)
execFileSync('npx', [
    'remotion', 'ffmpeg', '-hide_banner', '-loglevel', 'error',
    '-i', SRC,
    '-t', String(DUR - MUSIC_AT + 1),
    '-ac', '2', '-ar', String(SR),
    TMP, '-y',
], {cwd: ROOT, stdio: 'inherit'});

const wav   = readFileSync(TMP);
const dataAt = 44; // en-tête PCM canonique produit par ffmpeg
const frames = Math.floor((wav.length - dataAt) / 4);
const t0     = Math.round(MUSIC_AT * SR);

for (let i = 0; i < frames && t0 + i < N; i++) {
    const t   = (t0 + i) / SR;
    // Fondu d'entrée 0.3 s, fondu de sortie sur les 1.2 dernières secondes
    // Le fondu de sortie est calé pour raccorder en boucle avec le début.
    const fin  = Math.min(1, (t - MUSIC_AT) / 0.3);
    const fout = t > 13.5 ? Math.cos(((t - 13.5) / 1.2) * Math.PI * 0.5) ** 2 : 1;
    const g    = fin * fout;
    const l    = (wav.readInt16LE(dataAt + i * 4)     / 32768) * GAIN;
    const r    = (wav.readInt16LE(dataAt + i * 4 + 2) / 32768) * GAIN;
    L[t0 + i] += Math.tanh(l) * 0.9 * g;
    R[t0 + i] += Math.tanh(r) * 0.9 * g;
}

/** Pluck feutré façon harpe : partiels décroissants, queue qui chante. */
function pluck(t, f, vel, pan = 0.2) {
    const s0   = Math.round(t * SR);
    const T    = 1.4;
    const len  = Math.min(Math.round(3.0 * SR), N - s0);
    const parts = [1, 0.45, 0.22, 0.1];
    const gl   = 0.5 * (1 - pan);
    const gr   = 0.5 * (1 + pan);
    for (let p = 0; p < parts.length; p++) {
        const fp = f * (p + 1) * (1 + 0.0006 * (p + 1) * (p + 1));
        if (fp > SR / 2 - 1000) break;
        const w  = (2 * Math.PI * fp) / SR;
        const tp = T / (1 + 0.9 * p);
        const a  = vel * parts[p] * 0.2;
        for (let i = 0; i < len; i++) {
            const tt  = i / SR;
            const env = Math.min(1, tt / 0.006) * Math.exp(-tt / tp);
            const s   = a * env * Math.sin(w * i + p * 1.7);
            L[s0 + i] += s * gl;
            R[s0 + i] += s * gr;
        }
    }
}

/**
 * Le souffle : une vraie expiration, pas un sifflement statique.
 * Bande de bruit résonante (filtre état-variable) dont le centre GLISSE de
 * ~1800 Hz vers ~450 Hz — la bouche qui s'arrondit en fin d'expiration.
 * Enveloppe : montée douce (~0.2 s), corps, retombée longue.
 */
function souffle(t, vel = 0.3) {
    const s0  = Math.round(t * SR);
    const dur = 0.85;
    const len = Math.min(Math.round(dur * SR), N - s0);
    let lpL = 0, bpL = 0, lpR = 0, bpR = 0; // état du filtre par canal
    const q = 0.5; // amortissement : résonance douce — souffle, pas sifflet
    for (let i = 0; i < len; i++) {
        const x   = i / SR / dur;
        // Demi-sinus adouci : l'air monte, plafonne, retombe sans claquer
        const env = Math.pow(Math.sin(Math.PI * Math.min(1, x * 1.12)), 1.4);
        // Glissando du centre de bande : 1800 → 450 Hz
        const fc  = 450 + 1350 * Math.exp(-2.4 * x);
        const f   = 2 * Math.sin((Math.PI * fc) / SR);
        const nL  = ((Math.sin(i * 12.9898) * 43758.5453) % 1);
        const nR  = ((Math.sin(i * 78.233)  * 12543.8567) % 1);
        // Filtre état-variable (sortie passe-bande), un par canal pour la largeur stéréo
        lpL += f * bpL;  bpL += f * (nL - lpL - q * bpL);
        lpR += f * bpR;  bpR += f * (nR - lpR - q * bpR);
        L[s0 + i] += vel * env * bpL * 0.8;
        R[s0 + i] += vel * env * bpR * 0.8;
    }
}

/**
 * Le coup de tampon : ce que le TabStamp visuel raconte, en son.
 * Trois couches : choc mat (sinus 170→70 Hz, queue 50 ms), clic d'encre
 * (transitoire de bruit 8 ms), et l'accord PLAQUÉ — les notes quasi ensemble,
 * feutrées. L'impact porte le geste, l'accord porte l'harmonie I→IV→V.
 */
function tampon(t, notes, vel) {
    const s0  = Math.round(t * SR);
    const len = Math.min(Math.round(0.35 * SR), N - s0);
    let phase = 0, lp = 0;
    for (let i = 0; i < len; i++) {
        const tt = i / SR;
        // Le corps : hauteur qui tombe (le tampon s'écrase sur le papier)
        const f0 = 170 - 100 * Math.min(1, tt / 0.06);
        phase += (2 * Math.PI * f0) / SR;
        const body  = Math.exp(-tt / 0.05) * Math.sin(phase);
        // Le clic : bruit filtré très court, plus clair que le coup de brigadier
        const noise = (Math.sin(i * 91.337) * 28461.92) % 1;
        lp += 0.35 * (noise - lp);
        const click = Math.exp(-tt / 0.008) * lp * 1.6;
        const s = vel * 0.85 * (body * 0.9 + click);
        L[s0 + i] += s * 0.5;
        R[s0 + i] += s * 0.5;
    }
    // L'accord plaqué : écart 8 ms entre notes (un seul geste, pas un arpège)
    notes.forEach((f, i) =>
        pluck(t + 0.012 + i * 0.008, f, vel * (0.55 + i * 0.05), 0.15 - i * 0.04),
    );
}

// Table de fréquences — Db majeur : I (Db) → IV (Gb) → V (Ab)
const Hz = {
    Db4: 277.18, F4: 349.23, Ab4: 415.30, Db5: 554.37,
    Gb4: 369.99, Bb4: 466.16, Db5b: 554.37, Gb5: 739.99,
    Ab4b: 415.30, C5: 523.25, Eb5: 622.25, Ab5: 830.61,
};

// Les souffles sont calés sur l'apparition de chaque ghost (avant le Tab)
souffle(56 / 30);   // ghost scène 1
souffle(176 / 30);  // ghost scène 2
souffle(306 / 30);  // ghost scène 3 (pastille)

// Les 3 coups de tampon — montée I→IV→V en Db majeur, chacun un peu plus fort
tampon(88 / 30,  [Hz.Db4, Hz.F4, Hz.Ab4, Hz.Db5],   0.55); // scène 1 : Db (I)
tampon(208 / 30, [Hz.Gb4, Hz.Bb4, Hz.Db5b, Hz.Gb5], 0.62); // scène 2 : Gb (IV)
tampon(334 / 30, [Hz.Ab4b, Hz.C5, Hz.Eb5, Hz.Ab5],  0.70); // scène 3 : Ab (V) — la résolution

// Encodage WAV PCM 16 bits stéréo
const data = Buffer.alloc(N * 4);
for (let i = 0; i < N; i++) {
    data.writeInt16LE(Math.round(Math.max(-1, Math.min(1, L[i])) * 32767), i * 4);
    data.writeInt16LE(Math.round(Math.max(-1, Math.min(1, R[i])) * 32767), i * 4 + 2);
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
unlinkSync(TMP);
console.log(`écrit : ${OUT} (${((44 + data.length) / 1e6).toFixed(1)} Mo, ${DUR}s)`);
