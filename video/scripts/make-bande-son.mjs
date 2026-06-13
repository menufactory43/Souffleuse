// Bande-son de « Souffleuse » (montage en trois actes) : musique domaine
// public + les trois coups du brigadier + les gestes synchronisés des actes,
// mixés sur la timeline exacte de src/Main.tsx (30 fps) :
//   coups : 0.40 / 1.13 / 1.87 s · musique dès 3.2 s
//   Acte I   — souffle du ghost 14.23 s · arpège du Tab 15.97 s
//   Acte II  — souffle de la pastille 23.80 s · arpège du Tab 25.53 s
//   Acte III — accord ⌥⌘T 32.40 s · souffle de la rature 33.33 s ·
//              arpège de résolution 35.60 s + note couronnée
//   rideau 49.97 s · fin 53.2 s
// Le piano Satie est remonté (+13 dB) sous limiteur doux (tanh) : la prise
// d'origine est très douce et à forte dynamique. Les arpèges restent voisés
// dans l'harmonie du morceau de chaque preset.
import {execFileSync} from 'node:child_process';
import {readFileSync, writeFileSync, unlinkSync, existsSync} from 'node:fs';
import {dirname, join} from 'node:path';
import {fileURLToPath} from 'node:url';

// Deux ambiances : `satie` (défaut) et `rapide` (Chopin, Valse-minute,
// enregistrement Musopen domaine public). Usage : node make-bande-son.mjs [preset]
const PRESETS = {
    satie: {
        file: 'gnossienne.ogg',
        gain: 4.5, // prise très douce : +13 dB sous limiteur
        // fa mineur, l'harmonie de la Gnossienne
        arpeges: [
            [15.967, ['F4', 'Ab4', 'C5', 'F5'], 0.5],
            [25.533, ['Bb4', 'Db5', 'F5', 'Bb5'], 0.54],
            [35.6, ['C5', 'F5', 'Ab5', 'C6'], 0.58],
        ],
        crown: 'F6',
    },
    rapide: {
        file: 'valse-minute.flac',
        gain: 0.85, // prise déjà au niveau
        // ré bémol majeur, la tonalité de la valse : I → IV → V, ça grimpe
        arpeges: [
            [15.967, ['Db4', 'F4', 'Ab4', 'Db5'], 0.55],
            [25.533, ['Gb4', 'Bb4', 'Db5', 'Gb5'], 0.6],
            [35.6, ['Ab4', 'C5', 'Eb5', 'Ab5'], 0.66],
        ],
        crown: 'Db6',
    },
    valse: {
        file: 'valse-64-2.flac',
        gain: 0.9, // prise déjà au niveau
        // ut dièse mineur (op. 64 n° 2) : i → iv → V, en enharmonie
        arpeges: [
            [15.967, ['Db4', 'E4', 'Ab4', 'Db5'], 0.55],
            [25.533, ['Gb4', 'A4', 'Db5', 'Gb5'], 0.6],
            [35.6, ['Ab4', 'C5', 'Eb5', 'Ab5'], 0.66],
        ],
        crown: 'Db6',
    },
};
const PRESET = PRESETS[process.argv[2] ?? 'satie'];
if (!PRESET) throw new Error(`preset inconnu : ${process.argv[2]} (satie | rapide)`);

const ROOT = join(dirname(fileURLToPath(import.meta.url)), '..');
const SRC = join(ROOT, 'public', PRESET.file);
const TMP = '/tmp/bande-son-decode.wav';
const OUT = join(ROOT, 'public', 'bande-son.wav');

const SR = 44100;
const DUR = 53.2;
const MUSIC_AT = 3.2;
const N = Math.round(SR * DUR);
const L = new Float64Array(N);
const R = new Float64Array(N);

// Décodage via le ffmpeg embarqué de Remotion (pas de dépendance système).
execFileSync('npx', ['remotion', 'ffmpeg', '-hide_banner', '-loglevel', 'error',
    '-i', SRC, '-t', String(DUR - MUSIC_AT + 1), '-ac', '2', '-ar', String(SR), TMP, '-y'],
    {cwd: ROOT, stdio: 'inherit'});

const wav = readFileSync(TMP);
const dataAt = 44; // en-tête PCM canonique produit par ffmpeg
const frames = Math.floor((wav.length - dataAt) / 4);
const GAIN = PRESET.gain;
const t0 = Math.round(MUSIC_AT * SR);
for (let i = 0; i < frames && t0 + i < N; i++) {
    const t = (t0 + i) / SR;
    // fondu d'entrée 0.9 s, fondu de sortie sur les 1.8 dernières secondes
    const fin = Math.min(1, (t - MUSIC_AT) / 0.9);
    const fout = t > 51.3 ? Math.cos(((t - 51.3) / 1.8) * Math.PI * 0.5) ** 2 : 1;
    const g = fin * fout;
    const l = (wav.readInt16LE(dataAt + i * 4) / 32768) * GAIN;
    const r = (wav.readInt16LE(dataAt + i * 4 + 2) / 32768) * GAIN;
    L[t0 + i] += Math.tanh(l) * 0.9 * g;
    R[t0 + i] += Math.tanh(r) * 0.9 * g;
}

/** Le coup du brigadier : un choc grave et mat, hauteur qui retombe. */
function knock(t, vel) {
    const s0 = Math.round(t * SR);
    const len = Math.min(Math.round(0.4 * SR), N - s0);
    let phase = 0;
    let lp = 0;
    for (let i = 0; i < len; i++) {
        const tt = i / SR;
        const f0 = 82 - 30 * Math.min(1, tt / 0.12);
        phase += (2 * Math.PI * f0) / SR;
        const body = Math.exp(-tt / 0.075) * Math.sin(phase);
        const noise = (Math.sin(i * 12.9898) * 43758.5453) % 1;
        lp += 0.12 * (noise - lp);
        const thud = Math.exp(-tt / 0.012) * lp * 2.2;
        const s = vel * 0.5 * (body + thud);
        L[s0 + i] += s * 0.5;
        R[s0 + i] += s * 0.5;
    }
}
knock(0.4, 0.55);
knock(1.133, 0.6);
knock(1.867, 0.68);
knock(49.967, 0.22); // le rideau se ferme

/** Pluck feutré façon harpe : partiels décroissants, queue qui chante. */
function pluck(t, f, vel, pan = 0.2) {
    const s0 = Math.round(t * SR);
    const T = 1.7;
    const len = Math.min(Math.round(3.5 * SR), N - s0);
    const parts = [1, 0.45, 0.22, 0.1];
    const gl = 0.5 * (1 - pan);
    const gr = 0.5 * (1 + pan);
    for (let p = 0; p < parts.length; p++) {
        const fp = f * (p + 1) * (1 + 0.0006 * (p + 1) * (p + 1));
        if (fp > SR / 2 - 1000) break;
        const w = (2 * Math.PI * fp) / SR;
        const tp = T / (1 + 0.9 * p);
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

/** Le souffle : une respiration d'air feutrée quand la réplique se condense. */
function souffle(t, vel = 0.11) {
    const s0 = Math.round(t * SR);
    const len = Math.min(Math.round(0.9 * SR), N - s0);
    let lpL = 0, lpR = 0, deepL = 0, deepR = 0;
    for (let i = 0; i < len; i++) {
        const tt = i / SR;
        const env = Math.min(1, tt / 0.3) * (tt < 0.4 ? 1 : Math.exp(-(tt - 0.4) / 0.22));
        const nL = ((Math.sin(i * 12.9898) * 43758.5453) % 1);
        const nR = ((Math.sin(i * 78.233) * 12543.8567) % 1);
        // passe-bande grossier : on garde le souffle, ni le grave ni le sifflant
        lpL += 0.22 * (nL - lpL); deepL += 0.025 * (lpL - deepL);
        lpR += 0.22 * (nR - lpR); deepR += 0.025 * (lpR - deepR);
        L[s0 + i] += vel * env * (lpL - deepL);
        R[s0 + i] += vel * env * (lpR - deepR);
    }
}

// Les trois actes : le souffle quand le ghost (ou la pastille, ou la rature)
// paraît, l'arpège quand le geste le prend.
const Hz = {
    Db4: 277.18, E4: 329.63, F4: 349.23, Gb4: 369.99, Ab4: 415.3, A4: 440.0,
    Bb4: 466.16, C5: 523.25, Db5: 554.37, Eb5: 622.25, F5: 698.46, Gb5: 739.99,
    Ab5: 830.61, Bb5: 932.33, C6: 1046.5, Db6: 1108.73, F6: 1396.91,
};
const SOUFFLES = [14.233, 23.8, 33.333]; // ghost · pastille mid-line · rature
SOUFFLES.forEach((t) => souffle(t));
// ⌥⌘T : trois petits plucks graves serrés, comme trois touches qui tombent.
PRESET.arpeges[0][1].slice(0, 3).forEach((n, i) => pluck(32.4 + i * 0.025, Hz[n] / 2, 0.2));
PRESET.arpeges.forEach(([t, notes, vel]) =>
    notes.forEach((n, i) => pluck(t + i * 0.04, Hz[n], vel + i * 0.03)),
);
// La note couronnée : la relecture se résout, un aigu posé après l'arpège.
pluck(35.95, Hz[PRESET.crown], 0.5, 0.3);

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
const old = join(ROOT, 'public', 'musique.wav');
if (existsSync(old)) unlinkSync(old);
console.log(`écrit : ${OUT} (${((44 + data.length) / 1e6).toFixed(1)} Mo, ${DUR}s)`);
