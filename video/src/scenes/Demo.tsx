import {AbsoluteFill, interpolate, interpolateColors, random, useCurrentFrame} from 'remotion';
import {C, BODY, DISPLAY} from '../theme';
import {inkRise, sceneFade, settle, settleSlow} from '../helpers';

/**
 * Le trou du souffleur, en trois scènes : Mail, Messages, Notes. La sélection
 * voyage dans les onglets du bandeau, la réplique change, le carnet d'usage
 * compte les frappes épargnées. Partout où l'on écrit, le même geste : Tab.
 */
type Scene = {tab: string; app: string; typed: string; souffle: string};

const SCENES: Scene[] = [
    {
        tab: 'Mail',
        app: 'Mail · réponse à un devis',
        typed: 'Je reviens vers vous',
        souffle: ' avant la fin de la semaine avec une version corrigée du devis.',
    },
    {
        tab: 'Messages',
        app: 'Messages · à un proche',
        typed: "Je t'appelle dès que",
        souffle: ' je sors de réunion, promis.',
    },
    {
        tab: 'Notes',
        app: 'Notes · à ne pas oublier',
        typed: 'Penser à réserver le',
        souffle: ' restaurant pour samedi soir.',
    },
];

// Partition d'une mini-scène (frames locaux) — la musique est calée dessus.
export const INTRO = 20;
export const SC_LEN = 175;
const TYPE_FROM = 10;
const GHOST_FROM = 76;
const GHOST_STAGGER = 2.6;
export const PRESS = 128;          // la touche Tab s'enfonce ici
const TOOK_STAGGER = 1.6;

const charTimes = (k: number, typed: string): number[] => {
    const times: number[] = [];
    let t = TYPE_FROM;
    for (let i = 0; i < typed.length; i++) {
        const prev = typed[i - 1] ?? '';
        t += 2.0 + random(`frappe-${k}-${i}`) * 0.9 + (prev === ',' || prev === '.' ? 6 : 0);
        times.push(t);
    }
    return times;
};
const TIMES = SCENES.map((s, k) => charTimes(k, s.typed));

const clamp = {extrapolateLeft: 'clamp', extrapolateRight: 'clamp'} as const;

const Kbd = ({label, lit, press = 0}: {label: string; lit: boolean; press?: number}) => (
    <span
        style={{
            fontFamily: DISPLAY,
            fontWeight: 500,
            fontSize: 26,
            border: `2px solid ${lit ? C.rouge : C.ink}`,
            color: lit ? C.rouge : C.ink,
            borderRadius: 4,
            padding: '3px 18px',
            backgroundColor: C.paper,
            boxShadow: `${3 - press * 2}px ${3 - press * 2}px 0 rgba(26,22,19,${lit ? 0.3 : 0.25})`,
            display: 'inline-block',
            transform: `translateY(${press * 3}px)`,
        }}
    >
        {label}
    </span>
);

const MiniScene = ({scene, k, frame}: {scene: Scene; k: number; frame: number}) => {
    const S = INTRO + k * SC_LEN;
    const f = frame - S;
    const isLast = k === SCENES.length - 1;

    // Fondu croisé entre scènes ; la dernière reste pour le tableau final.
    const opacity = interpolate(
        frame,
        isLast
            ? [S, S + 10, S + SC_LEN + 60, S + SC_LEN + 61]
            : [S, S + 10, S + SC_LEN - 10, S + SC_LEN],
        [k === 0 ? 1 : 0, 1, 1, isLast ? 1 : 0],
        clamp,
    );
    if (frame < S - 5 || (!isLast && frame > S + SC_LEN + 5)) return null;

    const shown = TIMES[k].filter((t) => t <= f).length;
    const words = scene.souffle.trim().split(' ');
    const ghostDone = GHOST_FROM + words.length * GHOST_STAGGER + 14;
    const caretOpacity = 0.58 + 0.42 * Math.sin((frame / 51) * Math.PI * 2);

    const press = interpolate(f, [PRESS - 3, PRESS, PRESS + 4], [0, 1, 0], clamp);
    const flashAt = PRESS + words.length * TOOK_STAGGER + 8;
    const flash = interpolate(f, [flashAt - 1, flashAt, flashAt + 18], [0, 0.3, 0], clamp);

    // La didascalie d'hésitation : le creux, mis en scène.
    const hesite = interpolate(f, [58, 68, GHOST_FROM, GHOST_FROM + 8], [0, 1, 1, 0], clamp);

    return (
        <div style={{position: 'absolute', inset: '52px 56px 0', opacity}}>
            <p
                style={{
                    fontFamily: DISPLAY,
                    fontSize: 22,
                    letterSpacing: '0.2em',
                    textTransform: 'uppercase',
                    color: C.inkFaint,
                    margin: '0 0 30px',
                }}
            >
                <b style={{color: C.rouge, fontWeight: 700}}>Contexte :</b> {scene.app}
            </p>
            <p style={{fontFamily: BODY, fontSize: 46, lineHeight: 1.5, color: C.ink, margin: 0}}>
                <span style={{backgroundColor: `rgba(168,154,130,${flash})`, borderRadius: 4}}>
                    {scene.typed.slice(0, shown)}
                </span>
                <span
                    style={{
                        display: 'inline-block',
                        width: 4,
                        height: '1.02em',
                        margin: '0 2px -0.16em 1px',
                        backgroundColor: C.rouge,
                        opacity: caretOpacity,
                    }}
                />
                {words.map((w, i) => {
                    const start = GHOST_FROM + i * GHOST_STAGGER;
                    const t = interpolate(f, [start, start + 16], [0, 1], {easing: settleSlow, ...clamp});
                    const tookStart = PRESS + i * TOOK_STAGGER;
                    const took = interpolate(f, [tookStart, tookStart + 7], [0, 1], {easing: settle, ...clamp});
                    return (
                        <span
                            key={i}
                            style={{
                                display: 'inline-block',
                                whiteSpace: 'pre',
                                fontStyle: took > 0.5 ? 'normal' : 'italic',
                                color: interpolateColors(took, [0, 1], [C.ghost, C.ink]),
                                opacity: t,
                                filter: `blur(${(1 - t) * 6}px)`,
                                transform: `translate(${(1 - t) * -14}px, ${(1 - t) * 6}px)`,
                            }}
                        >
                            {' ' + w}
                        </span>
                    );
                })}
            </p>

            <p
                style={{
                    fontFamily: BODY,
                    fontStyle: 'italic',
                    fontSize: 27,
                    color: C.inkFaint,
                    margin: '14px 0 0 6px',
                    opacity: hesite,
                }}
            >
                (un temps — on cherche le mot)
            </p>

            {/* Les indices Tab / Esc */}
            <div
                style={{
                    position: 'absolute',
                    left: 0,
                    right: 0,
                    bottom: 34,
                    display: 'flex',
                    gap: 48,
                    alignItems: 'center',
                    paddingTop: 28,
                    borderTop: `1px solid rgba(26,22,19,0.22)`,
                    fontFamily: BODY,
                    fontSize: 28,
                    color: C.inkSoft,
                    opacity: interpolate(f, [GHOST_FROM + 8, GHOST_FROM + 24], [0, 1], clamp),
                }}
            >
                <span style={{display: 'inline-flex', gap: 16, alignItems: 'center'}}>
                    <Kbd label="Tab" lit={f >= ghostDone - 4 && f < PRESS + 14} press={press} /> pour accepter
                </span>
                <span style={{display: 'inline-flex', gap: 16, alignItems: 'center'}}>
                    <Kbd label="Esc" lit={false} /> pour laisser
                </span>
            </div>
        </div>
    );
};

export const Demo = ({duration}: {duration: number}) => {
    const frame = useCurrentFrame();

    // La feuille respire : lente avancée vers le spectateur, à peine sensible.
    const pushIn = 1 + interpolate(frame, [0, duration], [0, 0.045], clamp);

    // Carnet d'usage : les frappes épargnées s'additionnent à chaque prise.
    let saved = 0;
    SCENES.forEach((s, k) => {
        const at = INTRO + k * SC_LEN + PRESS;
        saved += Math.round(
            s.souffle.length * interpolate(frame, [at + 4, at + 18], [0, 1], {easing: settle, ...clamp}),
        );
    });
    const tallyOn = interpolate(frame, [INTRO + PRESS + 4, INTRO + PRESS + 18], [0, 1], clamp);

    const current = Math.min(
        SCENES.length - 1,
        Math.max(0, Math.floor((frame - INTRO) / SC_LEN)),
    );

    const outro = interpolate(frame, [INTRO + 3 * SC_LEN + 14, INTRO + 3 * SC_LEN + 34], [0, 1], clamp);

    return (
        <AbsoluteFill
            style={{
                justifyContent: 'center',
                alignItems: 'center',
                opacity: sceneFade(frame, duration, 10, 16),
            }}
        >
            <p
                style={{
                    ...inkRise(frame, 0),
                    fontFamily: BODY,
                    fontStyle: 'italic',
                    fontSize: 34,
                    color: C.inkSoft,
                    marginBottom: 40,
                }}
            >
                Le trou du souffleur : la réplique, glissée pile au moment de l'hésitation
            </p>

            {/* Le cadre letterpress : feuille posée sur l'affiche, ombre dure sans flou */}
            <div
                style={{
                    ...inkRise(frame, 6),
                    width: 1320,
                    transform: `scale(${pushIn})`,
                }}
            >
                <div
                    style={{
                        border: `2px solid ${C.ink}`,
                        borderRadius: 3,
                        backgroundColor: C.paperCard,
                        boxShadow: `inset 0 2px 0 rgba(255,255,255,0.6), 10px 14px 0 rgba(26,22,19,0.10)`,
                        overflow: 'hidden',
                    }}
                >
                    {/* Bandeau de programme : fleuron + onglets, la sélection voyage */}
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
                        <div style={{marginLeft: 'auto', display: 'flex', gap: 14}}>
                            {SCENES.map((s, k) => (
                                <span
                                    key={s.tab}
                                    style={{
                                        fontFamily: DISPLAY,
                                        fontSize: 22,
                                        letterSpacing: '0.12em',
                                        textTransform: 'uppercase',
                                        padding: '5px 16px',
                                        borderRadius: 2,
                                        border: `2px solid ${k === current ? C.rouge : 'transparent'}`,
                                        color: k === current ? C.rouge : C.inkFaint,
                                    }}
                                >
                                    {s.tab}
                                </span>
                            ))}
                        </div>
                    </div>

                    {/* La scène — hauteur fixe, les trois tableaux s'y succèdent */}
                    <div style={{position: 'relative', height: 392}}>
                        {SCENES.map((s, k) => (
                            <MiniScene key={k} scene={s} k={k} frame={frame} />
                        ))}
                    </div>
                </div>

                {/* Le carnet d'usage, tenu sous la feuille */}
                <p
                    style={{
                        fontFamily: BODY,
                        fontStyle: 'italic',
                        fontSize: 28,
                        color: C.inkFaint,
                        textAlign: 'right',
                        margin: '24px 4px 0',
                        opacity: tallyOn,
                    }}
                >
                    carnet d'usage —{' '}
                    <b style={{fontStyle: 'normal', fontFamily: DISPLAY, color: C.rouge, fontWeight: 700}}>
                        {saved}
                    </b>{' '}
                    frappes épargnées
                </p>
            </div>

            <p
                style={{
                    fontFamily: BODY,
                    fontStyle: 'italic',
                    fontSize: 32,
                    color: C.inkSoft,
                    marginTop: 30,
                    opacity: outro,
                }}
            >
                Partout où vous écrivez sur votre Mac. Tab, et c'est dit.
            </p>
        </AbsoluteFill>
    );
};
