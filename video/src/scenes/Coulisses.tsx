import {AbsoluteFill, interpolate, useCurrentFrame} from 'remotion';
import {C, BODY, DISPLAY} from '../theme';
import {inkRise, sceneFade} from '../helpers';

const VOEUX = ['Pas de compte.', 'Pas de cloud.', 'Aucune porte de sortie.'];

/** Les coulisses : l'encre pleine page, la promesse murmurée. */
export const Coulisses = ({duration}: {duration: number}) => {
    const frame = useCurrentFrame();

    return (
        <AbsoluteFill style={{opacity: sceneFade(frame, duration, 12, 16)}}>
            <AbsoluteFill style={{backgroundColor: C.ink, justifyContent: 'center', alignItems: 'center', textAlign: 'center'}}>
                <span
                    style={{
                        ...inkRise(frame, 6),
                        fontFamily: DISPLAY,
                        fontWeight: 500,
                        fontSize: 26,
                        letterSpacing: '0.28em',
                        textTransform: 'uppercase',
                        color: C.paperEdge,
                    }}
                >
                    Côté jardin, côté cour
                </span>
                <h2
                    style={{
                        ...inkRise(frame, 16, 24),
                        fontFamily: DISPLAY,
                        fontWeight: 700,
                        fontSize: 92,
                        lineHeight: 1.05,
                        color: C.paper,
                        margin: '38px 0 0',
                        maxWidth: 1380,
                    }}
                >
                    Ce qui se dit en coulisse reste en coulisse.
                </h2>

                <div style={{display: 'flex', gap: 56, marginTop: 72, alignItems: 'center'}}>
                    {VOEUX.map((v, i) => (
                        <span key={v} style={{display: 'flex', gap: 56, alignItems: 'center'}}>
                            {i > 0 ? (
                                <span
                                    style={{
                                        width: 9,
                                        height: 9,
                                        transform: 'rotate(45deg)',
                                        backgroundColor: C.paperEdge,
                                        opacity: interpolate(frame, [40 + i * 16, 56 + i * 16], [0, 0.7], {
                                            extrapolateLeft: 'clamp',
                                            extrapolateRight: 'clamp',
                                        }),
                                    }}
                                />
                            ) : null}
                            <span
                                style={{
                                    ...inkRise(frame, 38 + i * 16),
                                    fontFamily: BODY,
                                    fontStyle: 'italic',
                                    fontSize: 44,
                                    color: C.paperEdge,
                                }}
                            >
                                {v}
                            </span>
                        </span>
                    ))}
                </div>

                <p
                    style={{
                        ...inkRise(frame, 100),
                        fontFamily: BODY,
                        fontSize: 34,
                        color: C.paperEdge,
                        marginTop: 70,
                        maxWidth: 1100,
                    }}
                >
                    Souffleuse réfléchit directement sur votre Mac. Ce que vous écrivez ne part
                    nulle part : il n'existe aucun endroit où l'envoyer.
                </p>
            </AbsoluteFill>
        </AbsoluteFill>
    );
};
