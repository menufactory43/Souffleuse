import {AbsoluteFill, interpolate} from 'remotion';
import {C, BODY, DISPLAY} from '../theme';
import {inkRise} from '../helpers';

export const clamp = {extrapolateLeft: 'clamp', extrapolateRight: 'clamp'} as const;

/**
 * Carton d'entracte : le numéro d'acte en lettrines rouges, le titre en
 * Bodoni, la didascalie entre parenthèses — comme un intertitre de muet.
 */
export const ActeCard = ({
    frame,
    numero,
    titre,
    didascalie,
}: {
    frame: number;
    numero: string;
    titre: string;
    didascalie: string;
}) => {
    const out = interpolate(frame, [46, 58], [1, 0], clamp);
    if (frame > 62) return null;
    return (
        <AbsoluteFill
            style={{justifyContent: 'center', alignItems: 'center', textAlign: 'center', opacity: out}}
        >
            <div style={{...inkRise(frame, 0, 16), display: 'flex', alignItems: 'center', gap: 26}}>
                <div style={{width: 64, height: 2, backgroundColor: C.ink, opacity: 0.5}} />
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
                    {numero}
                </span>
                <div style={{width: 64, height: 2, backgroundColor: C.ink, opacity: 0.5}} />
            </div>
            <h2
                style={{
                    ...inkRise(frame, 6, 20),
                    fontFamily: DISPLAY,
                    fontWeight: 700,
                    fontSize: 112,
                    color: C.ink,
                    margin: '30px 0 0',
                }}
            >
                {titre}
            </h2>
            <p
                style={{
                    ...inkRise(frame, 16, 20),
                    fontFamily: BODY,
                    fontStyle: 'italic',
                    fontSize: 33,
                    color: C.inkSoft,
                    margin: '28px 0 0',
                }}
            >
                {didascalie}
            </p>
        </AbsoluteFill>
    );
};

/** La feuille letterpress : cadre d'encre, fleuron, numéro d'acte en lucarne. */
export const Sheet = ({
    frame,
    from,
    acte,
    height,
    children,
}: {
    frame: number;
    from: number;
    acte: string;
    height: number;
    children: React.ReactNode;
}) => (
    <div style={{...inkRise(frame, from), width: 1320}}>
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
                <svg width={36} height={25} viewBox="0 0 20 14">
                    <path d="M2 7 Q10 0 18 7" fill="none" stroke={C.rouge} strokeWidth={1.1} />
                    <circle cx={10} cy={7} r={1.2} fill={C.rouge} />
                </svg>
                <span
                    style={{
                        marginLeft: 'auto',
                        fontFamily: DISPLAY,
                        fontSize: 22,
                        letterSpacing: '0.18em',
                        textTransform: 'uppercase',
                        color: C.rouge,
                        border: `2px solid ${C.rouge}`,
                        borderRadius: 2,
                        padding: '5px 16px',
                    }}
                >
                    {acte}
                </span>
            </div>
            <div style={{position: 'relative', height}}>{children}</div>
        </div>
    </div>
);

/** Ligne « Contexte : … » en tête de feuille. */
export const Contexte = ({label}: {label: string}) => (
    <p
        style={{
            fontFamily: DISPLAY,
            fontSize: 22,
            letterSpacing: '0.2em',
            textTransform: 'uppercase',
            color: C.inkFaint,
            margin: '0 0 30px',
        }}
    >
        <b style={{color: C.rouge, fontWeight: 700}}>Contexte :</b> {label}
    </p>
);

/** Touche letterpress, identique à la démo d'origine. */
export const Kbd = ({label, lit, press = 0}: {label: string; lit: boolean; press?: number}) => (
    <span
        style={{
            fontFamily: DISPLAY,
            fontWeight: 500,
            fontSize: 26,
            border: `2px solid ${lit ? C.rouge : C.ink}`,
            color: lit ? C.rouge : C.ink,
            borderRadius: 4,
            padding: '3px 18px',
            backgroundColor: C.paper,
            boxShadow: `${3 - press * 2}px ${3 - press * 2}px 0 rgba(26,22,19,${lit ? 0.3 : 0.25})`,
            display: 'inline-block',
            transform: `translateY(${press * 3}px)`,
        }}
    >
        {label}
    </span>
);

/** Curseur d'encre clignotant ; `frame` global pour garder la phase du battement. */
export const Caret = ({frame}: {frame: number}) => (
    <span
        style={{
            display: 'inline-block',
            width: 4,
            height: '1.02em',
            margin: '0 1px -0.16em 1px',
            backgroundColor: C.rouge,
            opacity: 0.58 + 0.42 * Math.sin((frame / 51) * Math.PI * 2),
        }}
    />
);

/** Le rang d'indices Tab / Esc au bas de la feuille. */
export const HintRow = ({
    opacity,
    press,
    tabLit,
    tabLabel,
}: {
    opacity: number;
    press: number;
    tabLit: boolean;
    tabLabel: string;
}) => (
    <div
        style={{
            position: 'absolute',
            left: 0,
            right: 0,
            bottom: 34,
            display: 'flex',
            gap: 48,
            alignItems: 'center',
            paddingTop: 28,
            borderTop: `1px solid rgba(26,22,19,0.22)`,
            fontFamily: BODY,
            fontSize: 28,
            color: C.inkSoft,
            opacity,
        }}
    >
        <span style={{display: 'inline-flex', gap: 16, alignItems: 'center'}}>
            <Kbd label="Tab" lit={tabLit} press={press} /> {tabLabel}
        </span>
        <span style={{display: 'inline-flex', gap: 16, alignItems: 'center'}}>
            <Kbd label="Esc" lit={false} /> pour laisser
        </span>
    </div>
);
