import {AbsoluteFill, interpolate, useCurrentFrame} from 'remotion';
import {C, BODY} from '../theme';
import {sceneFade, settle} from '../helpers';

const STRIKES = [12, 34, 56];

/**
 * Le brigadier frappe les trois coups : trois traits d'encre qui claquent
 * (apparition sèche), puis restent posés en marque pâle avant le lever.
 */
export const TroisCoups = ({duration}: {duration: number}) => {
    const frame = useCurrentFrame();

    return (
        <AbsoluteFill
            style={{
                justifyContent: 'center',
                alignItems: 'center',
                opacity: sceneFade(frame, duration, 4, 16),
            }}
        >
            <div style={{display: 'flex', gap: 44, alignItems: 'flex-start', height: 120}}>
                {STRIKES.map((start, i) => {
                    const scaleY = interpolate(frame, [start, start + 4, start + 9], [0.25, 1.06, 1], {
                        easing: settle,
                        extrapolateLeft: 'clamp',
                        extrapolateRight: 'clamp',
                    });
                    const opacity = interpolate(frame, [start, start + 2, start + 12], [0, 1, 0.45], {
                        extrapolateLeft: 'clamp',
                        extrapolateRight: 'clamp',
                    });
                    return (
                        <div
                            key={i}
                            style={{
                                width: 7,
                                height: 120,
                                backgroundColor: C.ink,
                                opacity,
                                transform: `scaleY(${scaleY})`,
                                transformOrigin: 'top center',
                            }}
                        />
                    );
                })}
            </div>
            <p
                style={{
                    fontFamily: BODY,
                    fontStyle: 'italic',
                    fontSize: 34,
                    color: C.inkSoft,
                    marginTop: 64,
                    opacity: interpolate(frame, [70, 86], [0, 1], {
                        extrapolateLeft: 'clamp',
                        extrapolateRight: 'clamp',
                    }),
                }}
            >
                (on frappe les trois coups)
            </p>
        </AbsoluteFill>
    );
};
