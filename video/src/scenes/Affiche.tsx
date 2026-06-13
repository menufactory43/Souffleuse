import {AbsoluteFill, interpolate, useCurrentFrame} from 'remotion';
import {C, BODY, DISPLAY} from '../theme';
import {inkRise, sceneFade, settle} from '../helpers';

/** L'affiche de programme : « Ce soir », puis le titre qui s'imprime. */
export const Affiche = ({duration}: {duration: number}) => {
    const frame = useCurrentFrame();

    const filet = (from: number) =>
        interpolate(frame, [from, from + 26], [0, 1], {
            easing: settle,
            extrapolateLeft: 'clamp',
            extrapolateRight: 'clamp',
        });

    return (
        <AbsoluteFill
            style={{
                justifyContent: 'center',
                alignItems: 'center',
                opacity: sceneFade(frame, duration, 8, 18),
                textAlign: 'center',
            }}
        >
            {/* Double filet de programme, en tête */}
            <div style={{width: 1180, transform: `scaleX(${filet(0)})`}}>
                <div style={{borderTop: `2px solid ${C.ink}`, borderBottom: `2px solid ${C.ink}`, height: 10}} />
            </div>

            {/* Badge « Ce soir » */}
            <div style={{...inkRise(frame, 10), marginTop: 70, display: 'flex', alignItems: 'center', gap: 26}}>
                <div style={{width: 80, height: 2, backgroundColor: C.ink, opacity: 0.5}} />
                <div style={{border: `2px solid ${C.ink}`, padding: '12px 38px 10px'}}>
                    <span
                        style={{
                            fontFamily: DISPLAY,
                            fontWeight: 500,
                            fontSize: 27,
                            letterSpacing: '0.34em',
                            textTransform: 'uppercase',
                            color: C.rouge,
                        }}
                    >
                        Ce soir — en trois actes
                    </span>
                </div>
                <div style={{width: 80, height: 2, backgroundColor: C.ink, opacity: 0.5}} />
            </div>

            {/* Didascalie d'introduction */}
            <p
                style={{
                    ...inkRise(frame, 24),
                    fontFamily: BODY,
                    fontStyle: 'italic',
                    fontSize: 36,
                    color: C.inkSoft,
                    margin: '44px 0 18px',
                }}
            >
                Une aide à l'écriture qui ne quitte jamais votre Mac
            </p>

            {/* Le titre */}
            <h1 style={{...inkRise(frame, 36, 26), fontFamily: DISPLAY, fontWeight: 700, fontSize: 168, lineHeight: 0.96, color: C.ink, margin: 0}}>
                Le mot juste,
            </h1>
            <p
                style={{
                    ...inkRise(frame, 52, 26),
                    fontFamily: DISPLAY,
                    fontWeight: 500,
                    fontStyle: 'italic',
                    fontSize: 78,
                    color: C.rouge,
                    margin: '26px 0 0',
                }}
            >
                soufflé à voix basse
            </p>

            {/* Double filet, en pied */}
            <div style={{width: 1180, marginTop: 78, transform: `scaleX(${filet(40)})`}}>
                <div style={{borderTop: `2px solid ${C.ink}`, borderBottom: `2px solid ${C.ink}`, height: 10}} />
            </div>
        </AbsoluteFill>
    );
};
