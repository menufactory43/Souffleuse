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
import {settle, settleSlow} from '../helpers';
import {Caret, Kbd, clamp, VSheet, TabStamp, Tally} from './rafale-ui';
import {Grain} from '../Paper';

/**
 * Composition verticale « La rafale de Tab » — 3 scènes en cuts nets + chute compacte.
 * Format : 1080×1920, 30 fps, 450 frames (~15 s), boucle parfaite papier↔papier.
 *
 * Partition (frames) :
 *   Scène 1 (Mail formel)       :  0 – 115   → ghost 56,  Tab 88
 *   Scène 2 (Signal décontracté): 116 – 231   → ghost 176, Tab 208
 *   Scène 3 (milieu de phrase)  : 232 – 359   → ghost 306, Tab 334
 *   Chute (marque + CTA)        : 360 – 449   → fondu papier à 443
 *
 *   Les frontières mordent sur la fin de la scène précédente (cut dès que son
 *   geste est posé) et les feuilles montent vite (rise 14) : pas de trou de
 *   papier nu entre deux scènes — fatal en social, on perd le pouce.
 *   Raccord de boucle : frame 443→449 fond vers papier crème nu, identique à frame 0.
 */

// ─── Scène 1 — Mail formel ───────────────────────────────────────────────────
// Texte tapé visible dès frame 0 — on ouvre en pleine frappe (pas de carton d'intro).
const S1_TYPED   = 'Je reviens vers vous';
const S1_SOUFFLE = ' avant la fin de la semaine avec une version corrigée du devis.';
const S1_START   = 0;
const S1_GHOST   = 56;   // apparition du ghost
const S1_PRESS   = 88;   // Tab
const S1_STAGGER = 2.4;  // délai entre mots du ghost

// Frappe pré-calculée via random Remotion (reproductible, pas de Math.random)
const S1_TIMES: number[] = (() => {
    const times: number[] = [];
    let t = S1_START;
    for (let i = 0; i < S1_TYPED.length; i++) {
        const prev = S1_TYPED[i - 1] ?? '';
        t += 1.8 + random(`s1-frappe-${i}`) * 0.7 + (prev === ',' ? 4 : 0);
        times.push(t);
    }
    return times;
})();

// ─── Scène 2 — Signal décontracté ────────────────────────────────────────────
const S2_TYPED   = "Je t'appelle dès que";
const S2_SOUFFLE = ' je sors de réunion, promis.';
const S2_START   = 116;
const S2_GHOST   = 176;
const S2_PRESS   = 208;
const S2_STAGGER = 2.4;

const S2_TIMES: number[] = (() => {
    const times: number[] = [];
    let t = S2_START;
    for (let i = 0; i < S2_TYPED.length; i++) {
        t += 1.8 + random(`s2-frappe-${i}`) * 0.7;
        times.push(t);
    }
    return times;
})();

// ─── Scène 3 — Milieu de phrase (geste ActeMidLine) ─────────────────────────
// Une réplique déjà écrite ; le caret remonte, on insère au milieu.
// La phrase recomposée doit se lire d'une traite : base gauche + insertion
// tapée + ghost accepté + base droite = une réplique naturelle.
const S3_BASE         = 'Bonne idée pour la date, je vois ça avec tout le monde.';
const S3_CARET_TARGET = S3_BASE.indexOf('date,') + 'date,'.length; // juste après « date, »
const S3_INS          = ' disons jeudi';
const S3_GHOST        = ' en fin de journée —';
const S3_START        = 232;
const S3_TRAVEL       = [254, 272] as const; // caret remonte la ligne
const S3_TYPE_FROM    = 276;
const S3_GHOST_AT     = 306;  // l'insertion (13 car. ≈ 28 frames) est posée avant
const S3_PRESS        = 334;

const S3_TIMES: number[] = (() => {
    const times: number[] = [];
    let t = S3_TYPE_FROM;
    for (let i = 0; i < S3_INS.length; i++) {
        t += 1.8 + random(`s3-frappe-${i}`) * 0.7;
        times.push(t);
    }
    return times;
})();

// ─── Compteur persistant ─────────────────────────────────────────────────────
// Nombre de frappes épargnées : somme des souffles acceptés.
// saved monte par paliers à chaque Tab, de façon monotone croissante.
const SAVE1 = S1_SOUFFLE.length;               // ~64
const SAVE2 = SAVE1 + S2_SOUFFLE.length;       // ~64 + ~28 = ~92
const SAVE3 = SAVE2 + S3_GHOST.length;         // ~92 + ~25 = ~117

// ─── Durée totale ─────────────────────────────────────────────────────────────
export const RAFALE_FRAMES = 450;

// ─── Composant principal ─────────────────────────────────────────────────────
export const Rafale = () => {
    const frame = useCurrentFrame();

    // ── Tally : saved interpolé par paliers, animé en settle sur 12 frames ──
    const saved = Math.round(
        frame < S1_PRESS
            ? 0
            : frame < S1_PRESS + 12
              ? interpolate(frame, [S1_PRESS, S1_PRESS + 12], [0, SAVE1], {easing: settle, ...clamp})
              : frame < S2_PRESS
                ? SAVE1
                : frame < S2_PRESS + 12
                  ? interpolate(frame, [S2_PRESS, S2_PRESS + 12], [SAVE1, SAVE2], {easing: settle, ...clamp})
                  : frame < S3_PRESS
                    ? SAVE2
                    : frame < S3_PRESS + 12
                      ? interpolate(frame, [S3_PRESS, S3_PRESS + 12], [SAVE2, SAVE3], {easing: settle, ...clamp})
                      : SAVE3,
    );

    // Tally visible dès le premier Tab accepté, reste présent jusqu'à la fin
    const tallyVisible = interpolate(frame, [S1_PRESS + 2, S1_PRESS + 18], [0, 1], clamp);

    // ── Fondu de sortie pour le raccord de boucle (frame 443→449 = papier nu) ──
    // Frame 0 et frame 449 doivent être visuellement identiques : papier + grain.
    // On fond TOUT vers opacité 0, révélant le fond papier derrière.
    const loopFade = interpolate(frame, [443, 449], [1, 0], clamp);

    return (
        <AbsoluteFill style={{backgroundColor: C.paper}}>
            {/* Grain plein cadre — identique aux actes 16:9 */}
            <Grain />

            {/* Bande-son dédiée à la rafale */}
            <Audio src={staticFile('bande-son-rafale.wav')} />

            {/* Tally persistant en haut, centré, hors des scènes */}
            <div
                style={{
                    position: 'absolute',
                    top: 72,
                    left: 0,
                    right: 0,
                    display: 'flex',
                    justifyContent: 'center',
                    zIndex: 10,
                    opacity: loopFade,
                }}
            >
                <Tally saved={saved} visible={tallyVisible} />
            </div>

            {/* ── Contenu des scènes (fondu au raccord de boucle) ── */}
            <div style={{opacity: loopFade}}>
                {frame < S2_START && <Scene1 frame={frame} />}
                {frame >= S2_START && frame < S3_START && <Scene2 frame={frame} />}
                {frame >= S3_START && frame < 360 && <Scene3 frame={frame} />}
                {frame >= 360 && <Chute frame={frame} />}
            </div>
        </AbsoluteFill>
    );
};

// ─── Scène 1 : Mail formel ────────────────────────────────────────────────────
const Scene1 = ({frame}: {frame: number}) => {
    const words  = S1_SOUFFLE.trim().split(' ');
    const shown  = S1_TIMES.filter((t) => t <= frame).length;
    const press  = interpolate(frame, [S1_PRESS - 3, S1_PRESS, S1_PRESS + 4], [0, 1, 0], clamp);
    // Flash de sélection au Tab
    const flash  = interpolate(frame, [S1_PRESS, S1_PRESS + 2, S1_PRESS + 20], [0, 0.3, 0], clamp);

    return (
        <AbsoluteFill style={{justifyContent: 'center', alignItems: 'center'}}>
            <VSheet frame={frame} from={0} label="Mail" height={420}>
                <div style={{position: 'absolute', inset: '42px 44px 0'}}>
                    {/* Contexte discret en Bodoni italic */}
                    <p
                        style={{
                            fontFamily: DISPLAY,
                            fontStyle: 'italic',
                            fontSize: 19,
                            letterSpacing: '0.1em',
                            color: C.inkFaint,
                            margin: '0 0 18px',
                            textTransform: 'uppercase',
                        }}
                    >
                        réponse à un devis
                    </p>

                    {/* Corps du message — frappe + ghost */}
                    <p style={{fontFamily: BODY, fontSize: 38, lineHeight: 1.55, color: C.ink, margin: 0}}>
                        <span style={{backgroundColor: `rgba(168,154,130,${flash})`, borderRadius: 3}}>
                            {S1_TYPED.slice(0, shown)}
                        </span>
                        <Caret frame={frame} />
                        {words.map((w, i) => {
                            const start    = S1_GHOST + i * S1_STAGGER;
                            const appear   = interpolate(frame, [start, start + 16], [0, 1], {
                                easing: settleSlow,
                                ...clamp,
                            });
                            const tookStart = S1_PRESS + i * 1.4;
                            const took      = interpolate(frame, [tookStart, tookStart + 7], [0, 1], {
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
                                        filter: `blur(${(1 - appear) * 5}px)`,
                                        transform: `translate(${(1 - appear) * -10}px, ${(1 - appear) * 4}px)`,
                                    }}
                                >
                                    {' ' + w}
                                </span>
                            );
                        })}
                    </p>

                    {/* Indice Tab/Esc */}
                    <div
                        style={{
                            position: 'absolute',
                            left: 0,
                            right: 0,
                            bottom: 24,
                            display: 'flex',
                            gap: 36,
                            alignItems: 'center',
                            paddingTop: 22,
                            borderTop: `1px solid rgba(26,22,19,0.20)`,
                            fontFamily: BODY,
                            fontSize: 24,
                            color: C.inkSoft,
                            opacity: interpolate(frame, [S1_GHOST + 8, S1_GHOST + 22], [0, 1], clamp),
                        }}
                    >
                        <span style={{display: 'inline-flex', gap: 12, alignItems: 'center'}}>
                            <Kbd
                                label="Tab"
                                lit={frame >= S1_GHOST + 18 && frame < S1_PRESS + 12}
                                press={press}
                            />{' '}
                            pour accepter
                        </span>
                        <span style={{display: 'inline-flex', gap: 12, alignItems: 'center'}}>
                            <Kbd label="Esc" lit={false} /> ignorer
                        </span>
                    </div>
                </div>
            </VSheet>

            {/* Tampon Tab en dehors de la feuille, centré en dessous */}
            <div
                style={{
                    marginTop: 28,
                    display: 'flex',
                    justifyContent: 'center',
                    opacity: interpolate(frame, [S1_PRESS - 22, S1_PRESS - 8], [0, 1], clamp),
                }}
            >
                <TabStamp frame={frame} pressAt={S1_PRESS} />
            </div>
        </AbsoluteFill>
    );
};

// ─── Scène 2 : Signal décontracté ────────────────────────────────────────────
const Scene2 = ({frame}: {frame: number}) => {
    // Frame local pour les calculs internes (le frame global reste continu)
    const words  = S2_SOUFFLE.trim().split(' ');
    const shown  = S2_TIMES.filter((t) => t <= frame).length;
    const press  = interpolate(frame, [S2_PRESS - 3, S2_PRESS, S2_PRESS + 4], [0, 1, 0], clamp);
    const flash  = interpolate(frame, [S2_PRESS, S2_PRESS + 2, S2_PRESS + 20], [0, 0.3, 0], clamp);

    return (
        <AbsoluteFill style={{justifyContent: 'center', alignItems: 'center'}}>
            <VSheet frame={frame} from={S2_START} rise={14} label="Signal" height={380}>
                <div style={{position: 'absolute', inset: '42px 44px 0'}}>
                    <p
                        style={{
                            fontFamily: DISPLAY,
                            fontStyle: 'italic',
                            fontSize: 19,
                            letterSpacing: '0.1em',
                            color: C.inkFaint,
                            margin: '0 0 18px',
                            textTransform: 'uppercase',
                        }}
                    >
                        message direct · ton familier
                    </p>

                    <p style={{fontFamily: BODY, fontSize: 38, lineHeight: 1.55, color: C.ink, margin: 0}}>
                        <span style={{backgroundColor: `rgba(168,154,130,${flash})`, borderRadius: 3}}>
                            {S2_TYPED.slice(0, shown)}
                        </span>
                        <Caret frame={frame} />
                        {words.map((w, i) => {
                            const start    = S2_GHOST + i * S2_STAGGER;
                            const appear   = interpolate(frame, [start, start + 16], [0, 1], {
                                easing: settleSlow,
                                ...clamp,
                            });
                            const tookStart = S2_PRESS + i * 1.4;
                            const took      = interpolate(frame, [tookStart, tookStart + 7], [0, 1], {
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
                            left: 0,
                            right: 0,
                            bottom: 24,
                            display: 'flex',
                            gap: 36,
                            alignItems: 'center',
                            paddingTop: 22,
                            borderTop: `1px solid rgba(26,22,19,0.20)`,
                            fontFamily: BODY,
                            fontSize: 24,
                            color: C.inkSoft,
                            opacity: interpolate(frame, [S2_GHOST + 8, S2_GHOST + 22], [0, 1], clamp),
                        }}
                    >
                        <span style={{display: 'inline-flex', gap: 12, alignItems: 'center'}}>
                            <Kbd
                                label="Tab"
                                lit={frame >= S2_GHOST + 18 && frame < S2_PRESS + 12}
                                press={press}
                            />{' '}
                            pour accepter
                        </span>
                        <span style={{display: 'inline-flex', gap: 12, alignItems: 'center'}}>
                            <Kbd label="Esc" lit={false} /> ignorer
                        </span>
                    </div>
                </div>
            </VSheet>

            <div
                style={{
                    marginTop: 28,
                    display: 'flex',
                    justifyContent: 'center',
                    opacity: interpolate(frame, [S2_PRESS - 22, S2_PRESS - 8], [0, 1], clamp),
                }}
            >
                <TabStamp frame={frame} pressAt={S2_PRESS} />
            </div>
        </AbsoluteFill>
    );
};

// ─── Scène 3 : Milieu de phrase (geste ActeMidLine adapté vertical) ───────────
const Scene3 = ({frame}: {frame: number}) => {
    // Le caret remonte dans la phrase déjà écrite
    const caretIdx = Math.round(
        interpolate(frame, [S3_TRAVEL[0], S3_TRAVEL[1]], [S3_BASE.length, S3_CARET_TARGET], {
            easing: settle,
            ...clamp,
        }),
    );
    const shown    = S3_TIMES.filter((t) => t <= frame).length;
    const accepted = frame >= S3_PRESS;
    const right    = S3_BASE.slice(caretIdx);

    const press = interpolate(frame, [S3_PRESS - 3, S3_PRESS, S3_PRESS + 4], [0, 1, 0], clamp);
    const flash = interpolate(frame, [S3_PRESS, S3_PRESS + 2, S3_PRESS + 24], [0, 0.3, 0], clamp);

    // Pastille ghost ancrée sous le caret. Elle disparaît PILE au Tab : après
    // l'acceptation le caret saute en début de ligne 2 et un fondu de sortie
    // y traînerait un fragment rogné au bord de la feuille — le flash de
    // surlignage suffit à raconter la condensation du ghost dans la ligne.
    const pillIn = interpolate(frame, [S3_GHOST_AT, S3_GHOST_AT + 16], [0, 1], {easing: settle, ...clamp});
    const pillOn = frame >= S3_GHOST_AT && frame < S3_PRESS;

    // Note didascalie : le caret remonte
    const travelNote = interpolate(
        frame,
        [S3_TRAVEL[0] + 4, S3_TRAVEL[0] + 14, S3_TYPE_FROM + 16, S3_TYPE_FROM + 26],
        [0, 1, 1, 0],
        clamp,
    );

    return (
        <AbsoluteFill style={{justifyContent: 'center', alignItems: 'center'}}>
            <VSheet frame={frame} from={S3_START} rise={14} label="Insertion" height={460}>
                <div style={{position: 'absolute', inset: '42px 44px 0'}}>
                    <p
                        style={{
                            fontFamily: DISPLAY,
                            fontStyle: 'italic',
                            fontSize: 19,
                            letterSpacing: '0.1em',
                            color: C.inkFaint,
                            margin: '0 0 18px',
                            textTransform: 'uppercase',
                        }}
                    >
                        révision en plein milieu
                    </p>

                    <p style={{fontFamily: BODY, fontSize: 34, lineHeight: 1.6, color: C.ink, margin: 0}}>
                        <span style={{whiteSpace: 'pre-wrap'}}>{S3_BASE.slice(0, caretIdx)}</span>
                        <span
                            style={{
                                whiteSpace: 'pre-wrap',
                                backgroundColor: `rgba(168,154,130,${flash})`,
                                borderRadius: 3,
                            }}
                        >
                            {S3_INS.slice(0, shown) + (accepted ? S3_GHOST : '')}
                        </span>
                        {/* Ancre relative : la pastille s'y accroche en absolu sous la ligne */}
                        <span style={{position: 'relative'}}>
                            <Caret frame={frame} />
                            {pillOn ? (
                                <span
                                    style={{
                                        position: 'absolute',
                                        top: '1.28em',
                                        // Ancrée à droite du caret : elle s'étend vers la
                                        // gauche et ne déborde jamais du bord de la feuille.
                                        right: -6,
                                        zIndex: 2,
                                        whiteSpace: 'nowrap',
                                        fontFamily: BODY,
                                        fontStyle: 'italic',
                                        fontSize: 28,
                                        color: C.ghost,
                                        backgroundColor: C.paperCard,
                                        border: `1.5px solid ${C.ink}`,
                                        borderRadius: 4,
                                        padding: '4px 16px 5px',
                                        boxShadow: '4px 5px 0 rgba(26,22,19,0.12)',
                                        opacity: pillIn,
                                        filter: `blur(${(1 - pillIn) * 5}px)`,
                                        transform: `translateY(${(1 - pillIn) * 8}px)`,
                                    }}
                                >
                                    {/* Flèche de la pastille — côté caret, donc à droite */}
                                    <span
                                        style={{
                                            position: 'absolute',
                                            top: -6,
                                            right: 12,
                                            width: 10,
                                            height: 10,
                                            transform: 'rotate(45deg)',
                                            backgroundColor: C.paperCard,
                                            borderTop: `1.5px solid ${C.ink}`,
                                            borderLeft: `1.5px solid ${C.ink}`,
                                        }}
                                    />
                                    {S3_GHOST.trim()}
                                </span>
                            ) : null}
                        </span>
                        <span style={{whiteSpace: 'pre-wrap'}}>{right}</span>
                    </p>

                    {/* Note didascalie : le caret qui remonte */}
                    <p
                        style={{
                            fontFamily: BODY,
                            fontStyle: 'italic',
                            fontSize: 22,
                            color: C.inkFaint,
                            margin: '12px 0 0 4px',
                            opacity: travelNote,
                        }}
                    >
                        (le curseur revient au milieu de la réplique)
                    </p>

                    <div
                        style={{
                            position: 'absolute',
                            left: 0,
                            right: 0,
                            bottom: 24,
                            display: 'flex',
                            gap: 36,
                            alignItems: 'center',
                            paddingTop: 22,
                            borderTop: `1px solid rgba(26,22,19,0.20)`,
                            fontFamily: BODY,
                            fontSize: 24,
                            color: C.inkSoft,
                            opacity: interpolate(frame, [S3_GHOST_AT + 12, S3_GHOST_AT + 26], [0, 1], clamp),
                        }}
                    >
                        <span style={{display: 'inline-flex', gap: 12, alignItems: 'center'}}>
                            <Kbd
                                label="Tab"
                                lit={frame >= S3_GHOST_AT + 18 && frame < S3_PRESS + 12}
                                press={press}
                            />{' '}
                            insérer au caret
                        </span>
                        <span style={{display: 'inline-flex', gap: 12, alignItems: 'center'}}>
                            <Kbd label="Esc" lit={false} /> ignorer
                        </span>
                    </div>
                </div>
            </VSheet>

            <div
                style={{
                    marginTop: 28,
                    display: 'flex',
                    justifyContent: 'center',
                    opacity: interpolate(frame, [S3_PRESS - 22, S3_PRESS - 8], [0, 1], clamp),
                }}
            >
                <TabStamp frame={frame} pressAt={S3_PRESS} />
            </div>
        </AbsoluteFill>
    );
};

// ─── Chute : marque + tagline + CTA ──────────────────────────────────────────
const Chute = ({frame}: {frame: number}) => {
    // Apparition progressive des éléments de marque — dès le cut (360),
    // pour ne pas laisser de papier nu après la scène 3.
    const marqueIn  = interpolate(frame, [360, 378], [0, 1], {easing: settle, ...clamp});
    const taglineIn = interpolate(frame, [370, 392], [0, 1], {easing: settleSlow, ...clamp});
    const ctaIn     = interpolate(frame, [386, 406], [0, 1], {easing: settleSlow, ...clamp});

    return (
        <AbsoluteFill
            style={{
                justifyContent: 'center',
                alignItems: 'center',
                flexDirection: 'column',
                gap: 0,
            }}
        >
            {/* Marque — même traitement que l'Affiche 16:9 */}
            <div
                style={{
                    opacity: marqueIn,
                    transform: `translateY(${(1 - marqueIn) * 20}px)`,
                    textAlign: 'center',
                    marginBottom: 32,
                }}
            >
                {/* Fleuron SVG centré */}
                <svg
                    width={54}
                    height={38}
                    viewBox="0 0 20 14"
                    style={{display: 'block', margin: '0 auto 20px'}}
                >
                    <path d="M2 7 Q10 0 18 7" fill="none" stroke={C.rouge} strokeWidth={1.4} />
                    <circle cx={10} cy={7} r={1.5} fill={C.rouge} />
                </svg>
                <h1
                    style={{
                        fontFamily: DISPLAY,
                        fontWeight: 700,
                        fontSize: 96,
                        letterSpacing: '0.06em',
                        color: C.ink,
                        margin: 0,
                        lineHeight: 1,
                    }}
                >
                    Souffleuse
                </h1>
            </div>

            {/* Tagline */}
            <p
                style={{
                    fontFamily: BODY,
                    fontStyle: 'italic',
                    fontSize: 30,
                    color: C.inkSoft,
                    textAlign: 'center',
                    margin: '0 60px 40px',
                    lineHeight: 1.5,
                    opacity: taglineIn,
                    transform: `translateY(${(1 - taglineIn) * 12}px)`,
                }}
            >
                Le mot juste, soufflé à voix basse.
            </p>

            {/* CTA — filet rouge + URL */}
            <div
                style={{
                    opacity: ctaIn,
                    transform: `translateY(${(1 - ctaIn) * 10}px)`,
                    textAlign: 'center',
                }}
            >
                <div
                    style={{
                        width: 320,
                        height: 1,
                        backgroundColor: C.ink,
                        opacity: 0.3,
                        margin: '0 auto 20px',
                    }}
                />
                <p
                    style={{
                        fontFamily: BODY,
                        fontStyle: 'italic',
                        fontSize: 24,
                        color: C.inkFaint,
                        margin: '0 0 10px',
                    }}
                >
                    Gratuit pendant la bêta
                </p>
                <p
                    style={{
                        fontFamily: DISPLAY,
                        fontWeight: 500,
                        fontSize: 32,
                        letterSpacing: '0.12em',
                        color: C.rouge,
                        margin: 0,
                    }}
                >
                    souffleuse.app
                </p>
            </div>
        </AbsoluteFill>
    );
};
