import {AbsoluteFill, interpolate, useCurrentFrame} from 'remotion';
import {C, BODY, DISPLAY} from '../theme';
import {inkRise, sceneFade, settle} from '../helpers';

const RIDEAU = 150; // les pans de rideau se ferment ici

/** Le salut : la marque, l'appel, puis le rideau se ferme sur le colophon. */
export const Finale = ({duration}: {duration: number}) => {
    const frame = useCurrentFrame();

    const fleuron = interpolate(frame, [4, 40], [1, 0], {
        easing: settle,
        extrapolateLeft: 'clamp',
        extrapolateRight: 'clamp',
    });

    const curtain = interpolate(frame, [RIDEAU, RIDEAU + 34], [0, 1], {
        easing: settle,
        extrapolateLeft: 'clamp',
        extrapolateRight: 'clamp',
    });

    return (
        <AbsoluteFill style={{opacity: sceneFade(frame, duration, 10, 10)}}>
            <AbsoluteFill style={{justifyContent: 'center', alignItems: 'center', textAlign: 'center'}}>
                {/* Cul-de-lampe qui s'imprime */}
                <svg width={130} height={72} viewBox="0 0 40 22" style={{display: 'block'}}>
                    <path
                        d="M20 2 C 12 8, 12 14, 20 20 C 28 14, 28 8, 20 2 Z"
                        fill="none"
                        stroke={C.rouge}
                        strokeWidth={1.2}
                        pathLength={1}
                        strokeDasharray={1}
                        strokeDashoffset={fleuron}
                    />
                    <path
                        d="M4 20 Q12 18 18 20 M36 20 Q28 18 22 20"
                        fill="none"
                        stroke={C.rouge}
                        strokeWidth={1.2}
                        pathLength={1}
                        strokeDasharray={1}
                        strokeDashoffset={fleuron}
                    />
                </svg>

                <h2 style={{...inkRise(frame, 18, 24), fontFamily: DISPLAY, fontWeight: 700, fontSize: 124, color: C.ink, margin: '34px 0 0'}}>
                    Souffleuse
                </h2>
                <p
                    style={{
                        ...inkRise(frame, 32),
                        fontFamily: DISPLAY,
                        fontStyle: 'italic',
                        fontWeight: 500,
                        fontSize: 56,
                        color: C.rouge,
                        margin: '18px 0 0',
                    }}
                >
                    Le mot juste, soufflé à voix basse.
                </p>

                {/* L'appel */}
                <div
                    style={{
                        ...inkRise(frame, 52),
                        marginTop: 64,
                        display: 'inline-flex',
                        alignItems: 'center',
                        gap: 20,
                        backgroundColor: C.ink,
                        color: C.paper,
                        border: `2px solid ${C.ink}`,
                        padding: '24px 52px',
                        fontFamily: DISPLAY,
                        fontWeight: 500,
                        fontSize: 38,
                        letterSpacing: '0.04em',
                    }}
                >
                    <svg width={30} height={36} viewBox="0 0 15 18" fill={C.paper}>
                        <path d="M10.4 0c.1 1-.3 2-1 2.8-.6.7-1.7 1.3-2.7 1.2-.1-1 .4-2 1-2.7C8.4.6 9.5.1 10.4 0Zm2.6 12.9c-.4 1-.6 1.4-1.1 2.3-.7 1.3-1.8 2.9-3 2.9-1.1 0-1.4-.7-2.9-.7-1.5 0-1.8.7-2.9.7-1.3 0-2.3-1.4-3-2.7C-.5 14.4-.7 10.3.9 8c.8-1.1 2.1-1.8 3.4-1.8 1.3 0 2.1.7 3.1.7 1 0 1.6-.7 3.1-.7 1.1 0 2.3.6 3.1 1.7-2.7 1.5-2.3 5.4.3 5Z" />
                    </svg>
                    Télécharger pour Mac
                </div>
                <p style={{...inkRise(frame, 66), fontFamily: BODY, fontStyle: 'italic', fontSize: 30, color: C.inkFaint, marginTop: 30}}>
                    <b style={{fontStyle: 'normal', color: C.rouge}}>Gratuit pendant la bêta.</b>{' '}
                    macOS Sonoma (14) ou plus récent · puce Apple Silicon
                </p>
            </AbsoluteFill>

            {/* Le rideau : deux pans de papier qui se ferment, filet d'encre au bord */}
            <AbsoluteFill style={{overflow: 'hidden'}}>
                <div
                    style={{
                        position: 'absolute',
                        top: 0,
                        bottom: 0,
                        left: 0,
                        width: '50.2%',
                        backgroundColor: C.paperDeep,
                        borderRight: `2px solid ${C.ink}`,
                        transform: `translateX(${(curtain - 1) * 100}%)`,
                    }}
                />
                <div
                    style={{
                        position: 'absolute',
                        top: 0,
                        bottom: 0,
                        right: 0,
                        width: '50.2%',
                        backgroundColor: C.paperDeep,
                        borderLeft: `2px solid ${C.ink}`,
                        transform: `translateX(${(1 - curtain) * 100}%)`,
                    }}
                />
            </AbsoluteFill>

            {/* Sur le rideau fermé : le colophon */}
            <AbsoluteFill
                style={{
                    justifyContent: 'center',
                    alignItems: 'center',
                    textAlign: 'center',
                    opacity: interpolate(frame, [RIDEAU + 36, RIDEAU + 52], [0, 1], {
                        extrapolateLeft: 'clamp',
                        extrapolateRight: 'clamp',
                    }),
                }}
            >
                <p style={{fontFamily: DISPLAY, fontStyle: 'italic', fontWeight: 500, fontSize: 72, color: C.ink, margin: 0}}>
                    Rideau.
                </p>
                <p style={{fontFamily: BODY, fontStyle: 'italic', fontSize: 32, color: C.inkFaint, marginTop: 36, lineHeight: 1.7}}>
                    Achevé d'imprimer en Bodoni Moda &amp; Spectral, sur papier crème.
                    <br />
                    Aucun serveur n'a été dérangé pendant cette représentation.
                </p>
                <p
                    style={{
                        fontFamily: DISPLAY,
                        fontWeight: 500,
                        fontSize: 30,
                        letterSpacing: '0.28em',
                        textTransform: 'uppercase',
                        color: C.rouge,
                        marginTop: 48,
                    }}
                >
                    souffleuse.app
                </p>
            </AbsoluteFill>
        </AbsoluteFill>
    );
};
