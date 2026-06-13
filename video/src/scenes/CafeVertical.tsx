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
import {
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
} from './Cafe';

/**
 * « Le café bondé » — version VERTICALE 1080×1920 (Signal / réseaux / stories).
 * Même partition temporelle que le 16:9 (T identique) → la même bande-son
 * (bande-son-cafe.wav) se cale dessus. Seules les MISES EN PAGE changent :
 *   - le duel passe en colonne (la dictée vocale au-dessus, Souffleuse dessous) ;
 *   - les feuilles sont plus étroites ; les corps de texte ajustés au portrait.
 * Les briques animées (Brouhaha, Waveform, MontageApp) sont réutilisées telles
 * quelles depuis Cafe.tsx — une seule source de vérité.
 */

// ─── 1. Décor ────────────────────────────────────────────────────────────────
const DecorV = ({frame, dur}: {frame: number; dur: number}) => (
    <AbsoluteFill
        style={{
            justifyContent: 'center',
            alignItems: 'center',
            textAlign: 'center',
            padding: '0 80px',
            opacity: sceneFade(frame, dur, 12, 16),
        }}
    >
        <div style={{...inkRise(frame, 0, 16), display: 'flex', alignItems: 'center', gap: 22, marginBottom: 34}}>
            <div style={{width: 54, height: 2, backgroundColor: C.ink, opacity: 0.5}} />
            <span
                style={{
                    fontFamily: DISPLAY,
                    fontWeight: 500,
                    fontSize: 32,
                    letterSpacing: '0.3em',
                    textTransform: 'uppercase',
                    color: C.rouge,
                }}
            >
                Le numéro du café
            </span>
            <div style={{width: 54, height: 2, backgroundColor: C.ink, opacity: 0.5}} />
        </div>
        <h2
            style={{
                ...inkRise(frame, 8, 20),
                fontFamily: DISPLAY,
                fontWeight: 700,
                fontSize: 150,
                color: C.ink,
                margin: 0,
                lineHeight: 1.04,
            }}
        >
            Un café bondé.
        </h2>
        <p
            style={{
                ...inkRise(frame, 20, 20),
                fontFamily: BODY,
                fontStyle: 'italic',
                fontSize: 44,
                color: C.inkSoft,
                margin: '36px 0 0',
            }}
        >
            (quatorze heures — le bruit, partout)
        </p>
    </AbsoluteFill>
);

// ─── 2. Duel (empilé) ────────────────────────────────────────────────────────
const Fleuron = () => (
    <svg width={34} height={24} viewBox="0 0 20 14">
        <path d="M2 7 Q10 0 18 7" fill="none" stroke={C.rouge} strokeWidth={1.1} />
        <circle cx={10} cy={7} r={1.2} fill={C.rouge} />
    </svg>
);
const Mic = () => (
    <svg width={24} height={24} viewBox="0 0 24 24" fill="none" stroke={C.inkSoft} strokeWidth={1.6}>
        <rect x={9} y={3} width={6} height={11} rx={3} />
        <path d="M5 11a7 7 0 0 0 14 0" />
        <path d="M12 18v3" />
    </svg>
);

const VPanel = ({
    frame,
    from,
    label,
    labelColor,
    border,
    height,
    children,
}: {
    frame: number;
    from: number;
    label: string;
    labelColor: string;
    border: boolean;
    height: number;
    children: React.ReactNode;
}) => (
    <div style={{...inkRise(frame, from, 16), width: 980}}>
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
                    padding: '14px 28px',
                    borderBottom: `1px solid rgba(26,22,19,0.5)`,
                    backgroundColor: C.paperDeep,
                }}
            >
                {border ? <Fleuron /> : <Mic />}
                <span
                    style={{
                        marginLeft: 'auto',
                        fontFamily: DISPLAY,
                        fontSize: 24,
                        letterSpacing: '0.16em',
                        textTransform: 'uppercase',
                        color: labelColor,
                        border: border ? `2px solid ${labelColor}` : 'none',
                        borderRadius: 2,
                        padding: border ? '5px 16px' : 0,
                    }}
                >
                    {label}
                </span>
            </div>
            <div style={{position: 'relative', height, padding: '28px 34px'}}>{children}</div>
        </div>
    </div>
);

const DuelV = ({frame, from, dur}: {frame: number; from: number; dur: number}) => {
    const f = frame - from;

    // Panneau voix
    const heardShown = Math.min(
        DUEL_HEARD.length,
        Math.max(0, Math.floor(interpolate(f, [50, 150], [0, DUEL_HEARD.length], clamp))),
    );
    const verdict = interpolate(f, [158, 174], [0, 1], {easing: settle, ...clamp});
    const overheard = interpolate(f, [176, 194], [0, 1], {easing: settleSlow, ...clamp});

    // Panneau Souffleuse
    const typeFrom = 16;
    const ghostFrom = 56;
    const stagger = 2.4;
    const pressAt = 150;
    let tt = typeFrom;
    const typedTimes = DUEL_PREFIX.split('').map((_, i) => {
        tt += 2.0 + random(`duelv-frappe-${i}`) * 0.7;
        return tt;
    });
    const shown = typedTimes.filter((x) => x <= f).length;
    const words = DUEL_GHOST.trim().split(' ');
    const ghostDone = ghostFrom + words.length * stagger + 12;
    const press = interpolate(f, [pressAt - 3, pressAt, pressAt + 4], [0, 1, 0], clamp);
    const flash = interpolate(f, [pressAt, pressAt + 2, pressAt + 22], [0, 0.3, 0], clamp);

    const tail = interpolate(f, [206, 222], [0, 1], {easing: settleSlow, ...clamp});

    return (
        <AbsoluteFill
            style={{
                flexDirection: 'column',
                justifyContent: 'center',
                alignItems: 'center',
                padding: '0 50px',
                opacity: sceneFade(f, dur, 12, 18),
            }}
        >
            <p
                style={{
                    fontFamily: BODY,
                    fontStyle: 'italic',
                    fontSize: 34,
                    lineHeight: 1.4,
                    textAlign: 'center',
                    color: C.inkSoft,
                    margin: '0 0 28px',
                    opacity: interpolate(f, [4, 18], [0, 1], clamp),
                }}
            >
                Même message — « {DUEL_SPOKEN} » — au même instant.
            </p>

            {/* GAUCHE (haut) : la dictée vocale */}
            <VPanel frame={frame} from={from} label={RIVAL} labelColor={C.inkSoft} border={false} height={372}>
                <div style={{display: 'flex', alignItems: 'center', gap: 16, marginBottom: 18}}>
                    <Waveform frame={frame} from={from + 8} width={30} />
                    <span style={{fontFamily: BODY, fontStyle: 'italic', fontSize: 22, color: C.inkFaint}}>
                        il faut parler tout haut…
                    </span>
                </div>
                <p style={{fontFamily: BODY, fontSize: 38, lineHeight: 1.5, color: C.ink, margin: 0}}>
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
                <p style={{fontFamily: DISPLAY, fontSize: 24, color: C.rouge, margin: '22px 0 0', opacity: verdict}}>
                    ⟶ ce n'est pas ce que vous avez dit.
                </p>
                <div
                    style={{
                        position: 'absolute',
                        left: 34,
                        right: 34,
                        bottom: 20,
                        display: 'flex',
                        gap: 12,
                        alignItems: 'center',
                        paddingTop: 14,
                        borderTop: `1px solid rgba(26,22,19,0.20)`,
                        opacity: overheard,
                    }}
                >
                    {[0, 1, 2].map((i) => (
                        <svg key={i} width={24} height={24} viewBox="0 0 24 24" fill={C.inkFaint}>
                            <circle cx={12} cy={8} r={4} />
                            <path d="M4 21c0-4.4 3.6-8 8-8s8 3.6 8 8" />
                        </svg>
                    ))}
                    <span style={{fontFamily: BODY, fontStyle: 'italic', fontSize: 22, color: C.inkSoft}}>
                        …et toute la table d'à côté a entendu.
                    </span>
                </div>
            </VPanel>

            {/* DIVISEUR vs */}
            <div style={{display: 'flex', alignItems: 'center', gap: 18, margin: '14px 0'}}>
                <div style={{width: 90, height: 2, backgroundColor: C.ink, opacity: 0.3}} />
                <span style={{fontFamily: DISPLAY, fontWeight: 700, fontStyle: 'italic', fontSize: 42, color: C.rouge}}>
                    vs
                </span>
                <div style={{width: 90, height: 2, backgroundColor: C.ink, opacity: 0.3}} />
            </div>

            {/* DROITE (bas) : Souffleuse */}
            <VPanel frame={frame} from={from} label="Souffleuse" labelColor={C.rouge} border height={250}>
                <p
                    style={{
                        fontFamily: BODY,
                        fontStyle: 'italic',
                        fontSize: 22,
                        color: C.inkFaint,
                        margin: '0 0 16px',
                    }}
                >
                    …vous, vous tapez. Sans un mot.
                </p>
                <p style={{fontFamily: BODY, fontSize: 38, lineHeight: 1.5, color: C.ink, margin: 0}}>
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
                <div
                    style={{
                        position: 'absolute',
                        left: 34,
                        bottom: 20,
                        display: 'flex',
                        gap: 12,
                        alignItems: 'center',
                        fontFamily: BODY,
                        fontSize: 22,
                        color: C.inkSoft,
                        opacity: interpolate(f, [ghostFrom + 8, ghostFrom + 22], [0, 1], clamp),
                    }}
                >
                    <Kbd label="Tab" lit={f >= ghostDone - 4 && f < pressAt + 12} press={press} /> et c'est dit.
                </div>
            </VPanel>

            <p
                style={{
                    fontFamily: BODY,
                    fontStyle: 'italic',
                    fontSize: 32,
                    color: C.inkSoft,
                    margin: '30px 0 0',
                    opacity: tail,
                }}
            >
                Le bruit, ou le silence. À vous de voir.
            </p>
        </AbsoluteFill>
    );
};

// ─── 3. Souffle (feuille étroite, MontageApp réutilisé) ──────────────────────
const SouffleV = ({frame, from, dur}: {frame: number; from: number; dur: number}) => {
    const f = frame - from;
    const titleOut = interpolate(f, [0, 8, 16, 24], [0, 1, 1, 0], clamp);
    const codaFrom = APP_INTRO + PHRASES.length * APP_LEN;
    const coda = interpolate(f, [codaFrom - 30, codaFrom - 14], [0, 1], {easing: settleSlow, ...clamp});

    return (
        <AbsoluteFill
            style={{
                flexDirection: 'column',
                justifyContent: 'center',
                alignItems: 'center',
                padding: '0 60px',
                opacity: sceneFade(f, dur, 12, 18),
            }}
        >
            <p
                style={{
                    position: 'absolute',
                    top: 360,
                    fontFamily: BODY,
                    fontStyle: 'italic',
                    fontSize: 38,
                    textAlign: 'center',
                    color: C.inkSoft,
                    opacity: titleOut,
                }}
            >
                Partout sur votre Mac, sans dire un mot…
            </p>

            <div style={{...inkRise(frame, from + 4, 16), width: 960}}>
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
                        <Fleuron />
                        <span
                            style={{
                                marginLeft: 'auto',
                                fontFamily: DISPLAY,
                                fontSize: 24,
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
                    <div style={{position: 'relative', height: 460, padding: '44px 48px'}}>
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
                    textAlign: 'center',
                    color: C.inkSoft,
                    margin: '34px 0 0',
                    opacity: coda,
                }}
            >
                Pas un mot dit tout haut. Pas un octet qui sort de votre Mac.
            </p>
        </AbsoluteFill>
    );
};

// ─── 4. Bilan (empilé) ───────────────────────────────────────────────────────
const BilanV = ({frame, from, dur}: {frame: number; from: number; dur: number}) => {
    const f = frame - from;
    const cta = interpolate(f, [66, 84], [0, 1], {easing: settleSlow, ...clamp});
    return (
        <AbsoluteFill
            style={{
                flexDirection: 'column',
                justifyContent: 'center',
                alignItems: 'center',
                padding: '0 70px',
                opacity: sceneFade(f, dur, 12, 18),
            }}
        >
            <div style={{...inkRise(frame, from, 16), width: 940}}>
                <div style={{display: 'flex', justifyContent: 'flex-end', gap: 0, marginBottom: 14}}>
                    <span
                        style={{
                            flex: 1,
                            textAlign: 'center',
                            fontFamily: DISPLAY,
                            fontSize: 26,
                            letterSpacing: '0.12em',
                            textTransform: 'uppercase',
                            color: C.inkFaint,
                        }}
                    >
                        {RIVAL}
                    </span>
                    <span
                        style={{
                            flex: 1,
                            textAlign: 'center',
                            fontFamily: DISPLAY,
                            fontWeight: 700,
                            fontSize: 28,
                            letterSpacing: '0.12em',
                            textTransform: 'uppercase',
                            color: C.rouge,
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
                                padding: '16px 0',
                                borderTop: `1px solid rgba(26,22,19,0.22)`,
                                opacity: rowIn,
                                transform: `translateY(${(1 - rowIn) * 10}px)`,
                            }}
                        >
                            <p style={{fontFamily: DISPLAY, fontSize: 27, color: C.ink, margin: '0 0 8px'}}>{r.label}</p>
                            <div style={{display: 'flex'}}>
                                <span
                                    style={{
                                        flex: 1,
                                        textAlign: 'center',
                                        fontFamily: BODY,
                                        fontStyle: 'italic',
                                        fontSize: 25,
                                        color: C.inkFaint,
                                    }}
                                >
                                    ✗ {r.voix}
                                </span>
                                <span style={{flex: 1, textAlign: 'center', fontFamily: BODY, fontSize: 26, color: C.ink}}>
                                    <b style={{color: C.rouge}}>✓</b> {r.souffle}
                                </span>
                            </div>
                        </div>
                    );
                })}

                <div style={{textAlign: 'center', marginTop: 60, opacity: cta}}>
                    <h2 style={{fontFamily: DISPLAY, fontWeight: 700, fontSize: 92, color: C.ink, margin: 0}}>
                        Souffleuse
                    </h2>
                    <p style={{fontFamily: BODY, fontStyle: 'italic', fontSize: 38, color: C.inkSoft, margin: '16px 0 0'}}>
                        Elle souffle. Vous écrivez. En silence.
                    </p>
                </div>
            </div>
        </AbsoluteFill>
    );
};

// ─── Composition verticale ───────────────────────────────────────────────────
export const CafeVertical = () => {
    const frame = useCurrentFrame();
    const noiseLevel = interpolate(
        frame,
        [0, T.duel.from + T.duel.dur - 24, T.souffle.from + 24],
        [1, 1, 0],
        clamp,
    );

    return (
        <AbsoluteFill style={{backgroundColor: C.paper, fontFamily: BODY}}>
            <Audio src={staticFile('bande-son-cafe.wav')} />
            <Brouhaha level={noiseLevel} />

            {frame < T.duel.from && <DecorV frame={frame - T.decor.from} dur={T.decor.dur} />}
            {frame >= T.duel.from && frame < T.souffle.from && (
                <DuelV frame={frame} from={T.duel.from} dur={T.duel.dur} />
            )}
            {frame >= T.souffle.from && frame < T.bilan.from && (
                <SouffleV frame={frame} from={T.souffle.from} dur={T.souffle.dur} />
            )}
            {frame >= T.bilan.from && <BilanV frame={frame} from={T.bilan.from} dur={T.bilan.dur} />}

            <Grain />
        </AbsoluteFill>
    );
};
