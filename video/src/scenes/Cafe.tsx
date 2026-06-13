import {
    AbsoluteFill,
    Audio,
    interpolate,
    interpolateColors,
    random,
    staticFile,
    useCurrentFrame,
} from 'remotion';
import {C, BODY, DISPLAY} from '../theme';
import {settle, settleSlow, sceneFade, inkRise} from '../helpers';
import {Caret, Kbd, clamp} from './acte-ui';
import {Grain} from '../Paper';

/**
 * Composition « Le café bondé » — le numéro où l'on taille la dictée vocale.
 * 16:9, 1920×1080, 30 fps, 906 frames (~30,2 s). Autonome.
 *
 * Quatre temps, en cuts fondus (sceneFade par sous-scène) :
 *   1. Le décor   —   0 – 96    (le café, le brouhaha)
 *   2. Le duel    —  96 – 360   (split-screen : la dictée vocale VS Souffleuse,
 *                                 la même phrase, au même instant)
 *   3. Le souffle — 360 – 876   (Souffleuse, 3 phrases, ghost validé en 2 Tab, en silence)
 *   4. Le bilan   — 876 – 996   (voix vs souffle, CTA)
 *
 * Thèse : la dictée vocale promet « 10× plus vite » — à condition de pouvoir
 * parler tout haut. Dans un café bondé c'est impossible (bruit + vie privée +
 * audio expédié au cloud). Le souffle, lui, est muet et 100% on-device.
 */

// ─── Le rival, nommé en UN seul endroit ──────────────────────────────────────
// Archétype neutre par défaut (pas de risque de pub comparative). Pour nommer
// explicitement le concurrent, remplacer par 'Wispr Flow' — en assumant le
// risque marque/diffamation d'une affirmation non étayée.
const RIVAL = 'la dictée vocale';

// ─── Partition globale ───────────────────────────────────────────────────────
const T = {
    decor:   {from: 0,   dur: 96},
    duel:    {from: 96,  dur: 264},
    souffle: {from: 360, dur: 516},
    bilan:   {from: 876, dur: 120},
} as const;

export const CAFE_FRAMES = T.bilan.from + T.bilan.dur; // 996

// ─── Le brouhaha : mots de café qui flottent en fond ─────────────────────────
const NOISE_WORDS = [
    "l'addition",
    'deux cafés',
    'tu disais ?',
    'oui voilà',
    'la machine',
    'pardon —',
    "s'il vous plaît",
    'et avec ceci',
    'à emporter',
    'la table six',
    'un crème',
    "tu m'entends ?",
];

const Brouhaha = ({level}: {level: number}) => {
    const frame = useCurrentFrame();
    if (level <= 0.001) return null;
    return (
        <AbsoluteFill style={{pointerEvents: 'none', overflow: 'hidden'}}>
            {NOISE_WORDS.map((w, i) => {
                const seedX = random(`noise-x-${i}`);
                const seedY = random(`noise-y-${i}`);
                const seedS = random(`noise-s-${i}`);
                const drift = Math.sin((frame / (70 + seedS * 60)) * Math.PI * 2) * 14;
                const baseOp = 0.05 + seedS * 0.07;
                return (
                    <span
                        key={i}
                        style={{
                            position: 'absolute',
                            left: `${6 + seedX * 84}%`,
                            top: `${8 + seedY * 80}%`,
                            transform: `translateY(${drift}px) rotate(${(seedS - 0.5) * 8}deg)`,
                            fontFamily: BODY,
                            fontStyle: 'italic',
                            fontSize: 26 + seedS * 26,
                            color: C.inkFaint,
                            opacity: baseOp * level,
                            whiteSpace: 'nowrap',
                        }}
                    >
                        {w}
                    </span>
                );
            })}
        </AbsoluteFill>
    );
};

// ─── Forme d'onde (réutilisée dans le panneau « voix » du duel) ──────────────
const Waveform = ({frame, from, width = 34}: {frame: number; from: number; width?: number}) => {
    const f = frame - from;
    const live = interpolate(f, [0, 14], [0, 1], clamp);
    return (
        <div style={{display: 'flex', alignItems: 'center', gap: 4, height: 52}}>
            {Array.from({length: width}).map((_, i) => {
                const s = random(`wave-${i}`);
                const h = 8 + Math.abs(Math.sin((f / (5 + s * 7)) + i)) * (14 + s * 38) * live;
                return (
                    <div
                        key={i}
                        style={{
                            width: 4,
                            height: h,
                            borderRadius: 2,
                            backgroundColor: s > 0.78 ? C.rouge : C.inkSoft,
                            opacity: 0.5 + s * 0.5,
                        }}
                    />
                );
            })}
        </div>
    );
};

// ─── 1. Le décor ─────────────────────────────────────────────────────────────
const Decor = ({frame, dur}: {frame: number; dur: number}) => (
    <AbsoluteFill
        style={{
            justifyContent: 'center',
            alignItems: 'center',
            textAlign: 'center',
            opacity: sceneFade(frame, dur, 12, 16),
        }}
    >
        <div style={{...inkRise(frame, 0, 16), display: 'flex', alignItems: 'center', gap: 26}}>
            <div style={{width: 64, height: 2, backgroundColor: C.ink, opacity: 0.5}} />
            <span
                style={{
                    fontFamily: DISPLAY,
                    fontWeight: 500,
                    fontSize: 27,
                    letterSpacing: '0.34em',
                    textTransform: 'uppercase',
                    color: C.rouge,
                }}
            >
                Le numéro du café
            </span>
            <div style={{width: 64, height: 2, backgroundColor: C.ink, opacity: 0.5}} />
        </div>
        <h2
            style={{
                ...inkRise(frame, 8, 20),
                fontFamily: DISPLAY,
                fontWeight: 700,
                fontSize: 116,
                color: C.ink,
                margin: '30px 0 0',
            }}
        >
            Un café bondé.
        </h2>
        <p
            style={{
                ...inkRise(frame, 20, 20),
                fontFamily: BODY,
                fontStyle: 'italic',
                fontSize: 34,
                color: C.inkSoft,
                margin: '28px 0 0',
            }}
        >
            (quatorze heures — le bruit, partout)
        </p>
    </AbsoluteFill>
);

// ─── 2. Le duel : la même phrase, au même instant ────────────────────────────
// Tâche commune aux deux côtés : un message « On se retrouve devant le cinéma… ».
const DUEL_PREFIX = 'On se retrouve';
const DUEL_GHOST = ' devant le cinéma à 20 h.';
const DUEL_SPOKEN = 'On se retrouve devant le cinéma à 20 h';

// Côté voix : ce qui est transcrit — le bruit du café s'y infiltre (en rouge).
type W = {t: string; bad?: boolean};
const DUEL_HEARD: W[] = [
    {t: 'On'},
    {t: 'se'},
    {t: 'retrouve'},
    {t: 'devant'},
    {t: 'le'},
    {t: 'deux cafés', bad: true},
    {t: 'à'},
    {t: "l'addition", bad: true},
    {t: '?'},
];

// Cadre letterpress générique pour un panneau du duel.
const Panel = ({
    frame,
    from,
    label,
    labelColor,
    border,
    rise = 16,
    children,
}: {
    frame: number;
    from: number;
    label: string;
    labelColor: string;
    border: boolean;
    rise?: number;
    children: React.ReactNode;
}) => (
    <div style={{...inkRise(frame, from, rise), width: 820}}>
        <div
            style={{
                border: `2px solid ${C.ink}`,
                borderRadius: 3,
                backgroundColor: C.paperCard,
                boxShadow: `inset 0 2px 0 rgba(255,255,255,0.6), 8px 12px 0 rgba(26,22,19,0.10)`,
                overflow: 'hidden',
            }}
        >
            <div
                style={{
                    display: 'flex',
                    alignItems: 'center',
                    gap: 16,
                    padding: '12px 24px',
                    borderBottom: `1px solid rgba(26,22,19,0.5)`,
                    backgroundColor: C.paperDeep,
                }}
            >
                {/* Fleuron pour Souffleuse, micro pour la voix */}
                {border ? (
                    <svg width={30} height={21} viewBox="0 0 20 14">
                        <path d="M2 7 Q10 0 18 7" fill="none" stroke={C.rouge} strokeWidth={1.1} />
                        <circle cx={10} cy={7} r={1.2} fill={C.rouge} />
                    </svg>
                ) : (
                    <svg width={22} height={22} viewBox="0 0 24 24" fill="none" stroke={C.inkSoft} strokeWidth={1.6}>
                        <rect x={9} y={3} width={6} height={11} rx={3} />
                        <path d="M5 11a7 7 0 0 0 14 0" />
                        <path d="M12 18v3" />
                    </svg>
                )}
                <span
                    style={{
                        marginLeft: 'auto',
                        fontFamily: DISPLAY,
                        fontSize: 20,
                        letterSpacing: '0.16em',
                        textTransform: 'uppercase',
                        color: labelColor,
                        border: border ? `2px solid ${labelColor}` : 'none',
                        borderRadius: 2,
                        padding: border ? '4px 14px' : 0,
                    }}
                >
                    {label}
                </span>
            </div>
            <div style={{position: 'relative', height: 360, padding: '28px 30px'}}>{children}</div>
        </div>
    </div>
);

const Duel = ({frame, from, dur}: {frame: number; from: number; dur: number}) => {
    const f = frame - from;

    // — Panneau voix (gauche) —
    const heardShown = Math.min(
        DUEL_HEARD.length,
        Math.max(0, Math.floor(interpolate(f, [50, 150], [0, DUEL_HEARD.length], clamp))),
    );
    const verdict = interpolate(f, [158, 174], [0, 1], {easing: settle, ...clamp});
    const overheard = interpolate(f, [176, 194], [0, 1], {easing: settleSlow, ...clamp});

    // — Panneau Souffleuse (droite) —
    const typeFrom = 16;
    const ghostFrom = 56;
    const stagger = 2.4;
    const pressAt = 150;
    let tt = typeFrom;
    const typedTimes = DUEL_PREFIX.split('').map((_, i) => {
        tt += 2.0 + random(`duel-frappe-${i}`) * 0.7;
        return tt;
    });
    const shown = typedTimes.filter((x) => x <= f).length;
    const words = DUEL_GHOST.trim().split(' ');
    const ghostDone = ghostFrom + words.length * stagger + 12;
    const press = interpolate(f, [pressAt - 3, pressAt, pressAt + 4], [0, 1, 0], clamp);
    const flash = interpolate(f, [pressAt, pressAt + 2, pressAt + 22], [0, 0.3, 0], clamp);

    // Bandeau de bascule final
    const tail = interpolate(f, [206, 222], [0, 1], {easing: settleSlow, ...clamp});

    return (
        <AbsoluteFill
            style={{
                justifyContent: 'center',
                alignItems: 'center',
                opacity: sceneFade(f, dur, 12, 18),
            }}
        >
            {/* Intitulé : même message, deux mondes */}
            <p
                style={{
                    fontFamily: BODY,
                    fontStyle: 'italic',
                    fontSize: 30,
                    color: C.inkSoft,
                    margin: '0 0 26px',
                    opacity: interpolate(f, [4, 18], [0, 1], clamp),
                }}
            >
                Même message — « {DUEL_SPOKEN} » — au même instant, dans le même café.
            </p>

            <div style={{display: 'flex', alignItems: 'center', gap: 40}}>
                {/* GAUCHE : la dictée vocale */}
                <Panel frame={frame} from={from} label={RIVAL} labelColor={C.inkSoft} border={false}>
                    <div style={{display: 'flex', alignItems: 'center', gap: 16, marginBottom: 18}}>
                        <Waveform frame={frame} from={from + 8} width={26} />
                        <span style={{fontFamily: BODY, fontStyle: 'italic', fontSize: 19, color: C.inkFaint}}>
                            il faut parler tout haut…
                        </span>
                    </div>
                    <p style={{fontFamily: BODY, fontSize: 34, lineHeight: 1.5, color: C.ink, margin: 0}}>
                        {DUEL_HEARD.slice(0, heardShown).map((w, i) => (
                            <span
                                key={i}
                                style={{
                                    color: w.bad ? C.rouge : C.ink,
                                    fontStyle: w.bad ? 'italic' : 'normal',
                                    textDecoration: w.bad ? 'underline' : 'none',
                                    textDecorationColor: C.rouge,
                                }}
                            >
                                {(i > 0 ? ' ' : '') + w.t}
                            </span>
                        ))}
                        {heardShown < DUEL_HEARD.length && <Caret frame={frame} />}
                    </p>
                    <p
                        style={{
                            fontFamily: DISPLAY,
                            fontSize: 22,
                            color: C.rouge,
                            margin: '20px 0 0',
                            opacity: verdict,
                        }}
                    >
                        ⟶ ce n'est pas ce que vous avez dit.
                    </p>
                    <div
                        style={{
                            position: 'absolute',
                            left: 30,
                            right: 30,
                            bottom: 18,
                            display: 'flex',
                            gap: 12,
                            alignItems: 'center',
                            paddingTop: 14,
                            borderTop: `1px solid rgba(26,22,19,0.20)`,
                            opacity: overheard,
                        }}
                    >
                        {[0, 1, 2].map((i) => (
                            <svg key={i} width={22} height={22} viewBox="0 0 24 24" fill={C.inkFaint}>
                                <circle cx={12} cy={8} r={4} />
                                <path d="M4 21c0-4.4 3.6-8 8-8s8 3.6 8 8" />
                            </svg>
                        ))}
                        <span style={{fontFamily: BODY, fontStyle: 'italic', fontSize: 19, color: C.inkSoft}}>
                            …et toute la table d'à côté a entendu.
                        </span>
                    </div>
                </Panel>

                {/* DIVISEUR : VS */}
                <div style={{display: 'flex', flexDirection: 'column', alignItems: 'center', gap: 12}}>
                    <div style={{width: 2, height: 90, backgroundColor: C.ink, opacity: 0.3}} />
                    <span
                        style={{
                            fontFamily: DISPLAY,
                            fontWeight: 700,
                            fontStyle: 'italic',
                            fontSize: 40,
                            color: C.rouge,
                        }}
                    >
                        vs
                    </span>
                    <div style={{width: 2, height: 90, backgroundColor: C.ink, opacity: 0.3}} />
                </div>

                {/* DROITE : Souffleuse */}
                <Panel frame={frame} from={from} label="Souffleuse" labelColor={C.rouge} border>
                    <div style={{display: 'flex', alignItems: 'center', gap: 16, marginBottom: 18, height: 52}}>
                        <span style={{fontFamily: BODY, fontStyle: 'italic', fontSize: 19, color: C.inkFaint}}>
                            …vous, vous tapez. Sans un mot.
                        </span>
                    </div>
                    <p style={{fontFamily: BODY, fontSize: 34, lineHeight: 1.5, color: C.ink, margin: 0}}>
                        <span style={{backgroundColor: `rgba(168,154,130,${flash})`, borderRadius: 3}}>
                            {DUEL_PREFIX.slice(0, shown)}
                        </span>
                        <Caret frame={frame} />
                        {words.map((w, i) => {
                            const gs = ghostFrom + i * stagger;
                            const appear = interpolate(f, [gs, gs + 16], [0, 1], {easing: settleSlow, ...clamp});
                            const tookStart = pressAt + i * 1.4;
                            const took = interpolate(f, [tookStart, tookStart + 7], [0, 1], {easing: settle, ...clamp});
                            return (
                                <span
                                    key={i}
                                    style={{
                                        display: 'inline-block',
                                        whiteSpace: 'pre',
                                        fontStyle: took > 0.5 ? 'normal' : 'italic',
                                        color: interpolateColors(took, [0, 1], [C.ghost, C.ink]),
                                        opacity: appear,
                                        filter: `blur(${(1 - appear) * 5}px)`,
                                        transform: `translate(${(1 - appear) * -10}px, ${(1 - appear) * 4}px)`,
                                    }}
                                >
                                    {' ' + w}
                                </span>
                            );
                        })}
                    </p>
                    <p
                        style={{
                            fontFamily: DISPLAY,
                            fontSize: 22,
                            color: C.rouge,
                            margin: '20px 0 0',
                            opacity: interpolate(f, [pressAt + 6, pressAt + 20], [0, 1], clamp),
                        }}
                    >
                        ⟶ exactement ce que vous vouliez.
                    </p>
                    <div
                        style={{
                            position: 'absolute',
                            left: 30,
                            bottom: 18,
                            display: 'flex',
                            gap: 12,
                            alignItems: 'center',
                            paddingTop: 14,
                            fontFamily: BODY,
                            fontSize: 22,
                            color: C.inkSoft,
                            opacity: interpolate(f, [ghostFrom + 8, ghostFrom + 22], [0, 1], clamp),
                        }}
                    >
                        <Kbd label="Tab" lit={f >= ghostDone - 4 && f < pressAt + 12} press={press} /> et c'est dit.
                    </div>
                </Panel>
            </div>

            <p
                style={{
                    fontFamily: BODY,
                    fontStyle: 'italic',
                    fontSize: 32,
                    color: C.inkSoft,
                    margin: '28px 0 0',
                    opacity: tail,
                }}
            >
                Le bruit, ou le silence. À vous de voir.
            </p>
        </AbsoluteFill>
    );
};

// ─── 3. Le souffle : montage de phrases du quotidien, en silence ─────────────
// Démo simulée (les captures réelles ne rendaient pas assez proprement). Chaque
// ghost fait 4 mots, validés en DEUX coups de Tab (2 mots à chaque coup) — le
// geste réel de l'acceptation partielle de Souffleuse.
type Phrase = {app: string; contexte: string; typed: string; souffle: string};
const PHRASES: Phrase[] = [
    {app: 'Mail', contexte: 'réponse à un client', typed: 'Merci beaucoup pour', souffle: 'votre aide si précieuse.'},
    {app: 'Messages', contexte: 'à un proche', typed: 'Je vous réponds', souffle: 'dès que possible, promis.'},
    {app: 'Notes', contexte: 'un rappel', typed: "Je t'envoie le", souffle: 'document avant ce soir.'},
];

const APP_INTRO = 16;
const APP_LEN = 150;
const APP_TYPE_FROM = 6;
const APP_GHOST = 44; // 1er ghost (2 mots) apparaît — APRÈS la fin de la frappe
const APP_STAGGER = 2.6;
const APP_PRESS1 = 82; // 1er Tab → valide le ghost 1 ET déclenche le ghost 2
const APP_PRESS2 = 120; // 2e Tab → valide le ghost 2
const APP_GHOST2 = APP_PRESS1 + 8; // le 2e ghost n'apparaît qu'APRÈS le 1er Tab
const APP_CHUNK = 2; // mots par ghost

const phraseCharTimes = (k: number, typed: string): number[] => {
    const times: number[] = [];
    let t = APP_TYPE_FROM;
    for (let i = 0; i < typed.length; i++) {
        t += 1.5 + random(`cafe-frappe-${k}-${i}`) * 0.6;
        times.push(t);
    }
    return times;
};
const PHRASE_TIMES = PHRASES.map((p, k) => phraseCharTimes(k, p.typed));

const MontageApp = ({phrase, k, frame, from}: {phrase: Phrase; k: number; frame: number; from: number}) => {
    const start = from + APP_INTRO + k * APP_LEN;
    const f = frame - start;
    const isLast = k === PHRASES.length - 1;
    if (f < -8 || (!isLast && f > APP_LEN + 8)) return null;

    // Fondu croisé ; la dernière phrase reste affichée pour la coda.
    const opacity = isLast
        ? interpolate(f, [-8, 4], [0, 1], clamp)
        : interpolate(f, [-8, 4, APP_LEN - 8, APP_LEN], [0, 1, 1, 0], clamp);
    const shown = PHRASE_TIMES[k].filter((t) => t <= f).length;
    const words = phrase.souffle.trim().split(' ');

    // Deux coups de Tab : la touche s'enfonce à PRESS1 puis PRESS2.
    const press1 = interpolate(f, [APP_PRESS1 - 3, APP_PRESS1, APP_PRESS1 + 4], [0, 1, 0], clamp);
    const press2 = interpolate(f, [APP_PRESS2 - 3, APP_PRESS2, APP_PRESS2 + 4], [0, 1, 0], clamp);
    const press = Math.max(press1, press2);
    const tabLit = f >= APP_GHOST + 14 && f < APP_PRESS2 + 12;

    return (
        <div style={{position: 'absolute', inset: 0, opacity}}>
            <p
                style={{
                    fontFamily: DISPLAY,
                    fontSize: 22,
                    letterSpacing: '0.2em',
                    textTransform: 'uppercase',
                    color: C.inkFaint,
                    margin: '0 0 26px',
                }}
            >
                <b style={{color: C.rouge, fontWeight: 700}}>{phrase.app} :</b> {phrase.contexte}
            </p>
            <p style={{fontFamily: BODY, fontSize: 46, lineHeight: 1.5, color: C.ink, margin: 0}}>
                {phrase.typed.slice(0, shown)}
                <Caret frame={frame} />
                {words.map((w, i) => {
                    const inGhost1 = i < APP_CHUNK;
                    // Ghost 1 dès APP_GHOST ; ghost 2 SEULEMENT après le 1er Tab.
                    const appearAt = inGhost1
                        ? APP_GHOST + i * APP_STAGGER
                        : APP_GHOST2 + (i - APP_CHUNK) * APP_STAGGER;
                    const appear = interpolate(f, [appearAt, appearAt + 16], [0, 1], {easing: settleSlow, ...clamp});
                    // chaque ghost est validé par SON Tab (ghost 1 → PRESS1, ghost 2 → PRESS2)
                    const pressTime = inGhost1 ? APP_PRESS1 : APP_PRESS2;
                    const took = interpolate(f, [pressTime, pressTime + 7], [0, 1], {easing: settle, ...clamp});
                    return (
                        <span
                            key={i}
                            style={{
                                display: 'inline-block',
                                whiteSpace: 'pre',
                                fontStyle: took > 0.5 ? 'normal' : 'italic',
                                color: interpolateColors(took, [0, 1], [C.ghost, C.ink]),
                                opacity: appear,
                                filter: `blur(${(1 - appear) * 6}px)`,
                                transform: `translate(${(1 - appear) * -12}px, ${(1 - appear) * 5}px)`,
                            }}
                        >
                            {' ' + w}
                        </span>
                    );
                })}
            </p>

            <div
                style={{
                    position: 'absolute',
                    left: 0,
                    bottom: 26,
                    display: 'flex',
                    gap: 14,
                    alignItems: 'center',
                    fontFamily: BODY,
                    fontSize: 26,
                    color: C.inkSoft,
                    opacity: interpolate(f, [APP_GHOST + 8, APP_GHOST + 22], [0, 1], clamp),
                }}
            >
                <Kbd label="Tab" lit={tabLit} press={press} />
                <Kbd label="Tab" lit={tabLit} press={press2} />
                deux mots à chaque coup.
            </div>
        </div>
    );
};

const Souffle = ({frame, from, dur}: {frame: number; from: number; dur: number}) => {
    const f = frame - from;
    const titleOut = interpolate(f, [0, 8, 16, 24], [0, 1, 1, 0], clamp);
    const codaFrom = APP_INTRO + PHRASES.length * APP_LEN;
    const coda = interpolate(f, [codaFrom - 30, codaFrom - 14], [0, 1], {easing: settleSlow, ...clamp});

    return (
        <AbsoluteFill
            style={{
                justifyContent: 'center',
                alignItems: 'center',
                opacity: sceneFade(f, dur, 12, 18),
            }}
        >
            <p
                style={{
                    position: 'absolute',
                    top: 150,
                    fontFamily: BODY,
                    fontStyle: 'italic',
                    fontSize: 36,
                    color: C.inkSoft,
                    opacity: titleOut,
                }}
            >
                Partout sur votre Mac, sans dire un mot…
            </p>

            <div style={{...inkRise(frame, from + 4, 16), width: 1320}}>
                <div
                    style={{
                        border: `2px solid ${C.ink}`,
                        borderRadius: 3,
                        backgroundColor: C.paperCard,
                        boxShadow: `inset 0 2px 0 rgba(255,255,255,0.6), 10px 14px 0 rgba(26,22,19,0.10)`,
                        overflow: 'hidden',
                    }}
                >
                    <div
                        style={{
                            display: 'flex',
                            alignItems: 'center',
                            gap: 22,
                            padding: '14px 30px',
                            borderBottom: `1px solid rgba(26,22,19,0.5)`,
                            backgroundColor: C.paperDeep,
                        }}
                    >
                        <svg width={36} height={25} viewBox="0 0 20 14">
                            <path d="M2 7 Q10 0 18 7" fill="none" stroke={C.rouge} strokeWidth={1.1} />
                            <circle cx={10} cy={7} r={1.2} fill={C.rouge} />
                        </svg>
                        <span
                            style={{
                                marginLeft: 'auto',
                                fontFamily: DISPLAY,
                                fontSize: 22,
                                letterSpacing: '0.18em',
                                textTransform: 'uppercase',
                                color: C.rouge,
                                border: `2px solid ${C.rouge}`,
                                borderRadius: 2,
                                padding: '5px 16px',
                            }}
                        >
                            Souffleuse
                        </span>
                    </div>
                    <div style={{position: 'relative', height: 392, padding: '44px 56px'}}>
                        {PHRASES.map((p, k) => (
                            <MontageApp key={k} phrase={p} k={k} frame={frame} from={from} />
                        ))}
                    </div>
                </div>
            </div>

            <p
                style={{
                    fontFamily: BODY,
                    fontStyle: 'italic',
                    fontSize: 34,
                    color: C.inkSoft,
                    marginTop: 30,
                    opacity: coda,
                }}
            >
                Pas un mot dit tout haut. Pas un octet qui sort de votre Mac.
            </p>
        </AbsoluteFill>
    );
};

// ─── 4. Le bilan : voix vs souffle ───────────────────────────────────────────
const ROWS = [
    {label: 'Dans le café bondé', voix: 'on parle tout haut', souffle: 'rien à dire'},
    {label: 'Votre vie privée', voix: 'audio expédié au cloud', souffle: '100% sur votre Mac'},
    {label: 'La promesse de vitesse', voix: 'si vous pouvez parler', souffle: "Tab, et c'est dit"},
];

const Bilan = ({frame, from, dur}: {frame: number; from: number; dur: number}) => {
    const f = frame - from;
    const cta = interpolate(f, [66, 84], [0, 1], {easing: settleSlow, ...clamp});
    return (
        <AbsoluteFill
            style={{
                justifyContent: 'center',
                alignItems: 'center',
                opacity: sceneFade(f, dur, 12, 18),
            }}
        >
            <div style={{...inkRise(frame, from, 16), width: 1280}}>
                <div style={{display: 'grid', gridTemplateColumns: '1.1fr 1fr 1fr', alignItems: 'end', gap: 0, marginBottom: 18}}>
                    <span />
                    <span
                        style={{
                            fontFamily: DISPLAY,
                            fontSize: 28,
                            letterSpacing: '0.14em',
                            textTransform: 'uppercase',
                            color: C.inkFaint,
                            textAlign: 'center',
                        }}
                    >
                        {RIVAL}
                    </span>
                    <span
                        style={{
                            fontFamily: DISPLAY,
                            fontWeight: 700,
                            fontSize: 30,
                            letterSpacing: '0.14em',
                            textTransform: 'uppercase',
                            color: C.rouge,
                            textAlign: 'center',
                        }}
                    >
                        Souffleuse
                    </span>
                </div>

                {ROWS.map((r, i) => {
                    const rowIn = interpolate(f, [10 + i * 12, 24 + i * 12], [0, 1], {easing: settle, ...clamp});
                    return (
                        <div
                            key={i}
                            style={{
                                display: 'grid',
                                gridTemplateColumns: '1.1fr 1fr 1fr',
                                alignItems: 'center',
                                gap: 0,
                                padding: '18px 0',
                                borderTop: `1px solid rgba(26,22,19,0.22)`,
                                opacity: rowIn,
                                transform: `translateY(${(1 - rowIn) * 10}px)`,
                            }}
                        >
                            <span style={{fontFamily: DISPLAY, fontSize: 28, color: C.ink}}>{r.label}</span>
                            <span
                                style={{
                                    fontFamily: BODY,
                                    fontStyle: 'italic',
                                    fontSize: 26,
                                    color: C.inkFaint,
                                    textAlign: 'center',
                                }}
                            >
                                ✗ {r.voix}
                            </span>
                            <span style={{fontFamily: BODY, fontSize: 27, color: C.ink, textAlign: 'center'}}>
                                <b style={{color: C.rouge}}>✓</b> {r.souffle}
                            </span>
                        </div>
                    );
                })}

                <div style={{textAlign: 'center', marginTop: 48, opacity: cta}}>
                    <h2 style={{fontFamily: DISPLAY, fontWeight: 700, fontSize: 72, color: C.ink, margin: 0}}>
                        Souffleuse
                    </h2>
                    <p
                        style={{
                            fontFamily: BODY,
                            fontStyle: 'italic',
                            fontSize: 34,
                            color: C.inkSoft,
                            margin: '14px 0 0',
                        }}
                    >
                        Elle souffle. Vous écrivez. En silence.
                    </p>
                </div>
            </div>
        </AbsoluteFill>
    );
};

// ─── Composition ─────────────────────────────────────────────────────────────
export const Cafe = () => {
    const frame = useCurrentFrame();

    // Le brouhaha couvre décor + duel, puis se tait au souffle (silence = la thèse).
    const noiseLevel = interpolate(
        frame,
        [0, T.duel.from + T.duel.dur - 24, T.souffle.from + 24],
        [1, 1, 0],
        clamp,
    );

    return (
        <AbsoluteFill style={{backgroundColor: C.paper, fontFamily: BODY}}>
            {/* Brouhaha café → coupure nette au souffle → Gnossienne (make-bande-son-cafe.mjs) */}
            <Audio src={staticFile('bande-son-cafe.wav')} />
            <Brouhaha level={noiseLevel} />

            {frame < T.duel.from && <Decor frame={frame - T.decor.from} dur={T.decor.dur} />}
            {frame >= T.duel.from && frame < T.souffle.from && (
                <Duel frame={frame} from={T.duel.from} dur={T.duel.dur} />
            )}
            {frame >= T.souffle.from && frame < T.bilan.from && (
                <Souffle frame={frame} from={T.souffle.from} dur={T.souffle.dur} />
            )}
            {frame >= T.bilan.from && <Bilan frame={frame} from={T.bilan.from} dur={T.bilan.dur} />}

            <Grain />
        </AbsoluteFill>
    );
};

// Briques réutilisées par la version verticale (SouffleuseCafeVertical).
export {
    T,
    Brouhaha,
    Waveform,
    PHRASES,
    MontageApp,
    APP_INTRO,
    APP_LEN,
    RIVAL,
    DUEL_PREFIX,
    DUEL_GHOST,
    DUEL_SPOKEN,
    DUEL_HEARD,
    ROWS,
};
