import {Easing, interpolate} from 'remotion';

/** Décélération pure, jamais de rebond — la règle du système. */
export const settle = Easing.bezier(0.22, 0.68, 0.16, 1);
export const settleSlow = Easing.bezier(0.16, 0.74, 0.12, 1);

/** Fondu d'entrée/sortie d'une scène entière. */
export const sceneFade = (frame: number, duration: number, fadeIn = 12, fadeOut = 14) =>
    interpolate(
        frame,
        [0, fadeIn, duration - fadeOut, duration],
        [0, 1, 1, 0],
        {extrapolateLeft: 'clamp', extrapolateRight: 'clamp'},
    );

/** « L'encre qui se pose » : opacité + micro-translation + flou qui se résout. */
export const inkRise = (frame: number, from: number, len = 22) => {
    const t = interpolate(frame, [from, from + len], [0, 1], {
        easing: settle,
        extrapolateLeft: 'clamp',
        extrapolateRight: 'clamp',
    });
    return {
        opacity: t,
        transform: `translateY(${(1 - t) * 26}px)`,
        filter: `blur(${(1 - t) * 9}px)`,
    };
};
