import {AbsoluteFill, interpolate, useCurrentFrame} from 'remotion';
import {C, BODY, DISPLAY} from '../theme';
import {inkRise, sceneFade, settle} from '../helpers';
import {ActeCard, Contexte, Kbd, Sheet, clamp} from './acte-ui';

/**
 * Acte III — la relecture par ton : la réplique est dite, mais le metteur en
 * scène la veut plus formelle. ⌥⌘T, le HUD « FR ↺ relecture » choisit le ton
 * de la salle, la phrase est raturée à l'encre rouge et redite proprement.
 */
const CASUAL = "ok pour moi on part là-dessus, tu m'envoies le contrat ?";
const FORMAL = "C'est entendu, partons sur cette base. Pourriez-vous m'envoyer le contrat ?";
const TONS = ['Décontracté', 'Neutre', 'Formel'];
const CHIP_W = 178;

// Partition locale — la bande-son est calée sur KEYS_PRESS, STRIKE_AT, REWRITE_DONE.
export const KEYS_PRESS = 122;
const HUD_AT = 130;
export const STRIKE_AT = 150;
const REWRITE_FROM = 162;
const WORD_STAGGER = 4;

export const ActeRelecture = ({duration}: {duration: number}) => {
    const frame = useCurrentFrame();
    const words = FORMAL.split(' ');

    const press = interpolate(frame, [KEYS_PRESS - 3, KEYS_PRESS, KEYS_PRESS + 5], [0, 1, 0], clamp);
    const strike = interpolate(frame, [STRIKE_AT, STRIKE_AT + 18], [0, 1], {easing: settle, ...clamp});
    const dimmed = interpolate(frame, [STRIKE_AT, STRIKE_AT + 18], [1, 0.42], clamp);

    // Le sélecteur du HUD glisse Décontracté → Neutre → Formel, deux temps de valse.
    const chipX =
        CHIP_W *
        (interpolate(frame, [138, 146], [0, 1], {easing: settle, ...clamp}) +
            interpolate(frame, [149, 158], [0, 1], {easing: settle, ...clamp}));
    const chipIdx = Math.round(chipX / CHIP_W);

    const direction = interpolate(frame, [80, 94], [0, 1], clamp);
    const tally = interpolate(frame, [236, 250], [0, 1], clamp);
    const closing = interpolate(frame, [252, 272], [0, 1], clamp);

    return (
        <AbsoluteFill
            style={{justifyContent: 'center', alignItems: 'center', opacity: sceneFade(frame, duration, 8, 14)}}
        >
            <ActeCard
                frame={frame}
                numero="Acte III"
                titre="La relecture"
                didascalie="(le metteur en scène veut une autre version)"
            />
            {frame > 46 ? (
                <>
                    <Sheet frame={frame} from={50} acte="Acte III" height={486}>
                        <div style={{position: 'absolute', inset: '52px 56px 0'}}>
                            <Contexte label="Mail · réponse à un client" />

                            {/* La réplique trop familière, bientôt raturée */}
                            <p
                                style={{
                                    fontFamily: BODY,
                                    fontSize: 34,
                                    lineHeight: 1.55,
                                    color: C.ink,
                                    margin: 0,
                                    opacity: dimmed,
                                }}
                            >
                                <span style={{position: 'relative'}}>
                                    {CASUAL}
                                    <span
                                        style={{
                                            position: 'absolute',
                                            left: -2,
                                            right: -2,
                                            top: '52%',
                                            height: 3,
                                            backgroundColor: C.rouge,
                                            transform: `scaleX(${strike})`,
                                            transformOrigin: 'left center',
                                        }}
                                    />
                                </span>
                            </p>

                            {/* La même, redite dans le ton de la salle */}
                            <p
                                style={{
                                    fontFamily: BODY,
                                    fontSize: 34,
                                    lineHeight: 1.55,
                                    color: C.ink,
                                    margin: '14px 0 0',
                                }}
                            >
                                {words.map((w, i) => {
                                    const start = REWRITE_FROM + i * WORD_STAGGER;
                                    const t = interpolate(frame, [start, start + 14], [0, 1], {
                                        easing: settle,
                                        ...clamp,
                                    });
                                    return (
                                        <span
                                            key={i}
                                            style={{
                                                display: 'inline-block',
                                                whiteSpace: 'pre',
                                                opacity: t,
                                                filter: `blur(${(1 - t) * 6}px)`,
                                                transform: `translateY(${(1 - t) * 8}px)`,
                                            }}
                                        >
                                            {(i > 0 ? ' ' : '') + w}
                                        </span>
                                    );
                                })}
                            </p>

                            {/* La consigne du metteur en scène, le HUD en regard */}
                            <div
                                style={{
                                    display: 'flex',
                                    alignItems: 'center',
                                    justifyContent: 'space-between',
                                    gap: 24,
                                    marginTop: 30,
                                }}
                            >
                                <p
                                    style={{
                                        fontFamily: BODY,
                                        fontStyle: 'italic',
                                        fontSize: 28,
                                        color: C.inkFaint,
                                        margin: 0,
                                        opacity: direction,
                                        maxWidth: 520,
                                    }}
                                >
                                    Le metteur en scène, à mi-voix —
                                    <br />« <b style={{color: C.rouge, fontWeight: 600}}>On la refait. Plus formelle.</b> »
                                </p>
                                <div
                                    style={{
                                        ...inkRise(frame, HUD_AT, 18),
                                        border: `2px solid ${C.ink}`,
                                        borderRadius: 4,
                                        backgroundColor: C.paper,
                                        boxShadow: '6px 7px 0 rgba(26,22,19,0.12)',
                                        padding: '10px 14px 12px',
                                    }}
                                >
                                    <p
                                        style={{
                                            fontFamily: DISPLAY,
                                            fontSize: 19,
                                            letterSpacing: '0.2em',
                                            textTransform: 'uppercase',
                                            color: C.rouge,
                                            margin: '0 0 10px 2px',
                                        }}
                                    >
                                        FR ↺ relecture
                                    </p>
                                    <div
                                        style={{
                                            position: 'relative',
                                            display: 'flex',
                                            border: `1px solid rgba(26,22,19,0.4)`,
                                            borderRadius: 3,
                                        }}
                                    >
                                        <span
                                            style={{
                                                position: 'absolute',
                                                top: -1,
                                                bottom: -1,
                                                left: -1,
                                                width: CHIP_W + 2,
                                                border: `2px solid ${C.rouge}`,
                                                borderRadius: 3,
                                                transform: `translateX(${chipX}px)`,
                                            }}
                                        />
                                        {TONS.map((t, i) => (
                                            <span
                                                key={t}
                                                style={{
                                                    width: CHIP_W,
                                                    textAlign: 'center',
                                                    fontFamily: DISPLAY,
                                                    fontSize: 20,
                                                    letterSpacing: '0.08em',
                                                    padding: '7px 0 8px',
                                                    color: i === chipIdx ? C.rouge : C.inkFaint,
                                                    fontWeight: i === chipIdx ? 700 : 500,
                                                }}
                                            >
                                                {t}
                                            </span>
                                        ))}
                                    </div>
                                </div>
                            </div>

                            {/* Le geste : ⌥ ⌘ T */}
                            <div
                                style={{
                                    position: 'absolute',
                                    left: 0,
                                    right: 0,
                                    bottom: 34,
                                    display: 'flex',
                                    gap: 16,
                                    alignItems: 'center',
                                    paddingTop: 28,
                                    borderTop: `1px solid rgba(26,22,19,0.22)`,
                                    fontFamily: BODY,
                                    fontSize: 28,
                                    color: C.inkSoft,
                                    opacity: interpolate(frame, [102, 118], [0, 1], clamp),
                                }}
                            >
                                <Kbd label="⌥" lit={frame >= 110 && frame < KEYS_PRESS + 16} press={press} />
                                <Kbd label="⌘" lit={frame >= 110 && frame < KEYS_PRESS + 16} press={press} />
                                <Kbd label="T" lit={frame >= 110 && frame < KEYS_PRESS + 16} press={press} />
                                <span style={{marginLeft: 8}}>pour relire dans le ton de la salle</span>
                            </div>
                        </div>
                    </Sheet>
                    <div style={{width: 1320}}>
                        <p
                            style={{
                                fontFamily: BODY,
                                fontStyle: 'italic',
                                fontSize: 28,
                                color: C.inkFaint,
                                textAlign: 'right',
                                margin: '24px 4px 0',
                                opacity: tally,
                            }}
                        >
                            carnet d'usage —{' '}
                            <b style={{fontStyle: 'normal', color: C.rouge, fontWeight: 700}}>1</b> réplique
                            relue
                        </p>
                    </div>
                    <p
                        style={{
                            fontFamily: BODY,
                            fontStyle: 'italic',
                            fontSize: 32,
                            color: C.inkSoft,
                            marginTop: 26,
                            opacity: closing,
                        }}
                    >
                        Le ton suit la salle : décontracté entre proches, formel au bureau.
                    </p>
                </>
            ) : null}
        </AbsoluteFill>
    );
};
