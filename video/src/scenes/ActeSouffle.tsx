import {AbsoluteFill, interpolate, interpolateColors, random, useCurrentFrame} from 'remotion';
import {C, BODY} from '../theme';
import {sceneFade, settle, settleSlow} from '../helpers';
import {ActeCard, Caret, Contexte, HintRow, Sheet, clamp} from './acte-ui';

/**
 * Acte I — le geste fondateur : on tape, on hésite, la réplique paraît en
 * gris, Tab la prend. Une seule scène (Mail), resserrée — les actes II et III
 * montrent ce que la valse précédente ne montrait pas.
 */
const TYPED = 'Je reviens vers vous';
const SOUFFLE = ' avant la fin de la semaine avec une version corrigée du devis.';

// Partition locale (frames) — la bande-son est calée sur GHOST_FROM et PRESS.
const TYPE_FROM = 66;
export const GHOST_FROM = 132;
const GHOST_STAGGER = 2.6;
export const PRESS = 184;
const TOOK_STAGGER = 1.6;

const TIMES: number[] = (() => {
    const times: number[] = [];
    let t = TYPE_FROM;
    for (let i = 0; i < TYPED.length; i++) {
        const prev = TYPED[i - 1] ?? '';
        t += 2.0 + random(`souffle-frappe-${i}`) * 0.9 + (prev === ',' || prev === '.' ? 6 : 0);
        times.push(t);
    }
    return times;
})();

export const ActeSouffle = ({duration}: {duration: number}) => {
    const frame = useCurrentFrame();
    const words = SOUFFLE.trim().split(' ');
    const ghostDone = GHOST_FROM + words.length * GHOST_STAGGER + 14;

    const shown = TIMES.filter((t) => t <= frame).length;
    const press = interpolate(frame, [PRESS - 3, PRESS, PRESS + 4], [0, 1, 0], clamp);
    const flashAt = PRESS + words.length * TOOK_STAGGER + 8;
    const flash = interpolate(frame, [flashAt - 1, flashAt, flashAt + 18], [0, 0.3, 0], clamp);
    const hesite = interpolate(frame, [114, 124, GHOST_FROM, GHOST_FROM + 8], [0, 1, 1, 0], clamp);

    // Carnet d'usage : les frappes épargnées s'additionnent à la prise.
    const saved = Math.round(
        SOUFFLE.length * interpolate(frame, [PRESS + 4, PRESS + 18], [0, 1], {easing: settle, ...clamp}),
    );
    const tallyOn = interpolate(frame, [PRESS + 4, PRESS + 18], [0, 1], clamp);
    const outro = interpolate(frame, [220, 240], [0, 1], clamp);

    return (
        <AbsoluteFill
            style={{justifyContent: 'center', alignItems: 'center', opacity: sceneFade(frame, duration, 8, 14)}}
        >
            <ActeCard
                frame={frame}
                numero="Acte premier"
                titre="Le souffle"
                didascalie="(l'hésitation, puis la réplique glissée à voix basse)"
            />
            {frame > 46 ? (
                <>
                    <Sheet frame={frame} from={50} acte="Acte I" height={392}>
                        <div style={{position: 'absolute', inset: '52px 56px 0'}}>
                            <Contexte label="Mail · réponse à un devis" />
                            <p style={{fontFamily: BODY, fontSize: 46, lineHeight: 1.5, color: C.ink, margin: 0}}>
                                <span style={{backgroundColor: `rgba(168,154,130,${flash})`, borderRadius: 4}}>
                                    {TYPED.slice(0, shown)}
                                </span>
                                <Caret frame={frame} />
                                {words.map((w, i) => {
                                    const start = GHOST_FROM + i * GHOST_STAGGER;
                                    const t = interpolate(frame, [start, start + 16], [0, 1], {
                                        easing: settleSlow,
                                        ...clamp,
                                    });
                                    const tookStart = PRESS + i * TOOK_STAGGER;
                                    const took = interpolate(frame, [tookStart, tookStart + 7], [0, 1], {
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
                            <HintRow
                                opacity={interpolate(frame, [GHOST_FROM + 8, GHOST_FROM + 24], [0, 1], clamp)}
                                press={press}
                                tabLit={frame >= ghostDone - 4 && frame < PRESS + 14}
                                tabLabel="pour accepter"
                            />
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
                                opacity: tallyOn,
                            }}
                        >
                            carnet d'usage —{' '}
                            <b style={{fontStyle: 'normal', color: C.rouge, fontWeight: 700}}>{saved}</b>{' '}
                            frappes épargnées
                        </p>
                    </div>
                    <p
                        style={{
                            fontFamily: BODY,
                            fontStyle: 'italic',
                            fontSize: 32,
                            color: C.inkSoft,
                            marginTop: 26,
                            opacity: outro,
                        }}
                    >
                        Partout où vous écrivez sur votre Mac. Tab, et c'est dit.
                    </p>
                </>
            ) : null}
        </AbsoluteFill>
    );
};
