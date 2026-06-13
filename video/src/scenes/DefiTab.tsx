import {
    AbsoluteFill,
    interpolate,
    interpolateColors,
    random,
    useCurrentFrame,
    useVideoConfig,
} from 'remotion';
import {C, BODY, DISPLAY} from '../theme';
import {settle, settleSlow, inkRise} from '../helpers';
import {Caret, Kbd, clamp} from './acte-ui';
import {Grain} from '../Paper';

/**
 * « Le défi Tab » — short hook : 1 mot tapé + Tab = la phrase entière.
 * Démontre l'équation, CHIFFRE le gain (frappes épargnées), finit sur la perso.
 * Un seul composant, rendu en vertical (1080×1920) ET 16:9 (1920×1080) :
 * la mise en page s'adapte via useVideoConfig. 300 frames @30fps (~10 s).
 *
 * Beats : frappe « Merci » → ghost rouge complet → Tab×5 (2 mots/coup, rouge→noir,
 * compteur de frappes quasi figé) → climax « 56 frappes épargnées » →
 * punch « …et c'est écrit comme TOI » → CTA « 1 mot + Tab = la phrase entière ».
 */
export const DEFITAB_FRAMES = 300;

const PREFIX = 'Merci';
const GHOST = ' infiniment pour votre retour, je reviens vers vous dès demain.';
const GHOST_WORDS = GHOST.trim().split(' '); // 10 mots
const CHUNK = 2; // mots validés par Tab
const N_TABS = Math.ceil(GHOST_WORDS.length / CHUNK); // 5

// Compteur honnête : longueur réelle de la phrase vs frappes réellement faites.
const FULL_LEN = (PREFIX + GHOST).length; // ~66
const KEYS_USED = PREFIX.length + N_TABS; // 5 + 5 = 10
const SAVED = FULL_LEN - KEYS_USED; // ~56

// Frappe de « Merci » (reproductible via random Remotion)
const TYPE_FROM = 8;
const TYPE_TIMES = (() => {
    const t = [];
    let acc = TYPE_FROM;
    for (let i = 0; i < PREFIX.length; i++) {
        acc += 3.2 + random(`defi-frappe-${i}`) * 1.0;
        t.push(acc);
    }
    return t;
})();

const GHOST_AT = 40;
const GHOST_STAGGER = 2.2;
const TAB0 = 66;
const TAB_STEP = 22;
const TAB_FRAMES = Array.from({length: N_TABS}, (_, i) => TAB0 + i * TAB_STEP); // 66,88,110,132,154
const LAST_TAB = TAB_FRAMES[N_TABS - 1];

// Phases (frames)
const DEMO_END = 196;
const PUNCH_AT = 188;
const CTA_AT = 240;

export const DefiTab = () => {
    const frame = useCurrentFrame();
    const {width, height} = useVideoConfig();
    const vertical = height > width;

    // Tailles adaptées au format
    const S = {
        hook: vertical ? 42 : 40,
        card: vertical ? 940 : 1280,
        phrase: vertical ? 52 : 50,
        counter: vertical ? 30 : 30,
        big: vertical ? 120 : 132,
        punch: vertical ? 66 : 74,
        cta: vertical ? 90 : 96,
        ctaSub: vertical ? 36 : 38,
    };

    // ── Compteur de frappes ──
    const typedShown = TYPE_TIMES.filter((t) => t <= frame).length;
    const tabsPressed = TAB_FRAMES.filter((t) => frame >= t).length;
    const keysUsed = typedShown + tabsPressed;

    // ── Opacités de phase ──
    const hookOp = interpolate(frame, [0, 10, 56, 66], [0, 1, 1, 0], clamp);
    const demoOp = interpolate(frame, [0, 8, DEMO_END - 12, DEMO_END], [0, 1, 1, 0], clamp);
    const punchOp = interpolate(frame, [PUNCH_AT, PUNCH_AT + 12, CTA_AT - 10, CTA_AT], [0, 1, 1, 0], clamp);
    const ctaOp = interpolate(frame, [CTA_AT, CTA_AT + 14], [0, 1], clamp);

    // Climax compteur (après le dernier Tab) : « FULL → KEYS » puis « SAVED épargnées »
    const climaxA = interpolate(frame, [LAST_TAB + 4, LAST_TAB + 16], [0, 1], {easing: settle, ...clamp});

    // Bump de la touche Tab à chaque pression
    const press = Math.max(
        0,
        ...TAB_FRAMES.map((t) => interpolate(frame, [t - 3, t, t + 4], [0, 1, 0], clamp)),
    );
    const tabLit = frame >= GHOST_AT + 12 && frame < LAST_TAB + 12;

    return (
        <AbsoluteFill style={{backgroundColor: C.paper, fontFamily: BODY}}>
            {/* HOOK (haut, se retire avant les Tab) */}
            <div
                style={{
                    position: 'absolute',
                    top: vertical ? '13%' : '11%',
                    left: 0,
                    right: 0,
                    textAlign: 'center',
                    padding: '0 90px',
                    opacity: hookOp,
                }}
            >
                <p
                    style={{
                        ...inkRise(frame, 0, 14),
                        fontFamily: BODY,
                        fontStyle: 'italic',
                        fontSize: S.hook,
                        lineHeight: 1.35,
                        color: C.inkSoft,
                        margin: 0,
                    }}
                >
                    Cette phrase, je la finis sans taper une seule lettre.
                    <br />
                    <b style={{fontStyle: 'normal', color: C.rouge}}>Juste Tab.</b>
                </p>
            </div>

            {/* DÉMO : feuille letterpress + frappe + ghost + Tab */}
            <AbsoluteFill style={{justifyContent: 'center', alignItems: 'center', opacity: demoOp}}>
                <div style={{...inkRise(frame, 4, 14), width: S.card}}>
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
                                padding: '12px 26px',
                                borderBottom: `1px solid rgba(26,22,19,0.5)`,
                                backgroundColor: C.paperDeep,
                            }}
                        >
                            <svg width={32} height={22} viewBox="0 0 20 14">
                                <path d="M2 7 Q10 0 18 7" fill="none" stroke={C.rouge} strokeWidth={1.1} />
                                <circle cx={10} cy={7} r={1.2} fill={C.rouge} />
                            </svg>
                            <span
                                style={{
                                    marginLeft: 'auto',
                                    fontFamily: DISPLAY,
                                    fontSize: 20,
                                    letterSpacing: '0.18em',
                                    textTransform: 'uppercase',
                                    color: C.rouge,
                                    border: `2px solid ${C.rouge}`,
                                    borderRadius: 2,
                                    padding: '4px 14px',
                                }}
                            >
                                Souffleuse
                            </span>
                        </div>

                        <div style={{padding: vertical ? '44px 44px 36px' : '48px 56px 38px'}}>
                            <p style={{fontFamily: BODY, fontSize: S.phrase, lineHeight: 1.5, color: C.ink, margin: 0}}>
                                {PREFIX.slice(0, typedShown)}
                                {frame < TAB0 && <Caret frame={frame} />}
                                {GHOST_WORDS.map((w, i) => {
                                    const gs = GHOST_AT + i * GHOST_STAGGER;
                                    const appear = interpolate(frame, [gs, gs + 16], [0, 1], {
                                        easing: settleSlow,
                                        ...clamp,
                                    });
                                    const tFrame = TAB_FRAMES[Math.floor(i / CHUNK)];
                                    const took = interpolate(frame, [tFrame, tFrame + 7], [0, 1], {
                                        easing: settle,
                                        ...clamp,
                                    });
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
                                                transform: `translate(${(1 - appear) * -10}px, ${(1 - appear) * 4}px)`,
                                            }}
                                        >
                                            {' ' + w}
                                        </span>
                                    );
                                })}
                            </p>
                        </div>
                    </div>

                    {/* Sous la feuille : touche Tab + compteur de frappes */}
                    <div
                        style={{
                            display: 'flex',
                            alignItems: 'center',
                            justifyContent: 'space-between',
                            marginTop: 26,
                            opacity: interpolate(frame, [GHOST_AT + 6, GHOST_AT + 20], [0, 1], clamp),
                        }}
                    >
                        <span style={{display: 'inline-flex', gap: 14, alignItems: 'center', fontFamily: BODY, fontSize: S.counter, color: C.inkSoft}}>
                            <Kbd label="Tab" lit={tabLit} press={press} />
                            <span>×{tabsPressed}</span>
                        </span>
                        {/* Compteur de frappes — reste minuscule pendant que le texte explose */}
                        {climaxA < 0.5 ? (
                            <span style={{fontFamily: DISPLAY, fontSize: S.counter, color: C.inkFaint, letterSpacing: '0.04em'}}>
                                frappes :{' '}
                                <b style={{color: C.rouge, fontWeight: 700, fontFamily: DISPLAY}}>{keysUsed}</b>
                            </span>
                        ) : (
                            <span style={{fontFamily: DISPLAY, fontSize: S.counter, color: C.inkFaint, opacity: climaxA}}>
                                <s>{FULL_LEN} frappes</s>{' '}
                                <b style={{color: C.rouge, fontWeight: 700}}>→ {KEYS_USED}</b>
                            </span>
                        )}
                    </div>

                    {/* Le gros chiffre : frappes épargnées */}
                    <div style={{textAlign: 'center', marginTop: 22, opacity: climaxA}}>
                        <span style={{fontFamily: DISPLAY, fontWeight: 700, fontSize: S.big, color: C.rouge, lineHeight: 1}}>
                            −{SAVED}
                        </span>
                        <span style={{display: 'block', fontFamily: BODY, fontStyle: 'italic', fontSize: S.counter + 4, color: C.inkSoft, marginTop: 2}}>
                            frappes épargnées
                        </span>
                    </div>
                </div>
            </AbsoluteFill>

            {/* PUNCH perso */}
            <AbsoluteFill style={{justifyContent: 'center', alignItems: 'center', textAlign: 'center', padding: '0 80px', opacity: punchOp}}>
                <h2
                    style={{
                        ...inkRise(frame, PUNCH_AT, 16),
                        fontFamily: DISPLAY,
                        fontWeight: 700,
                        fontSize: S.punch,
                        color: C.ink,
                        margin: 0,
                        lineHeight: 1.15,
                    }}
                >
                    …et c'est écrit
                    <br />
                    comme <span style={{color: C.rouge}}>toi</span>.
                </h2>
                <p
                    style={{
                        ...inkRise(frame, PUNCH_AT + 10, 16),
                        fontFamily: BODY,
                        fontStyle: 'italic',
                        fontSize: S.counter + 4,
                        color: C.inkSoft,
                        margin: '24px 0 0',
                    }}
                >
                    elle apprend ta façon d'écrire — 100% sur ton Mac.
                </p>
            </AbsoluteFill>

            {/* CTA */}
            <AbsoluteFill style={{justifyContent: 'center', alignItems: 'center', textAlign: 'center', padding: '0 80px', opacity: ctaOp}}>
                <p
                    style={{
                        ...inkRise(frame, CTA_AT, 16),
                        fontFamily: BODY,
                        fontStyle: 'italic',
                        fontSize: S.ctaSub,
                        color: C.inkSoft,
                        margin: '0 0 18px',
                    }}
                >
                    1 mot + Tab = la phrase entière.
                </p>
                <h1
                    style={{
                        ...inkRise(frame, CTA_AT + 8, 18),
                        fontFamily: DISPLAY,
                        fontWeight: 700,
                        fontSize: S.cta,
                        color: C.ink,
                        margin: 0,
                    }}
                >
                    Souffleuse
                </h1>
            </AbsoluteFill>

            <Grain />
        </AbsoluteFill>
    );
};
