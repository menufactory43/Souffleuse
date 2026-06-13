import {interpolate} from 'remotion';
import {C, BODY, DISPLAY} from '../theme';
import {inkRise, settle, settleSlow} from '../helpers';

/**
 * Variante verticale d'acte-ui — même DA Livret, dimensionnée pour le 1080×1920.
 * On réutilise Kbd/Caret/clamp depuis acte-ui ; VSheet/TabStamp/Tally sont
 * des composants propres au format social vertical.
 */

// Re-export des primitives partagées — les scènes rafale n'importent qu'ici.
export {Kbd, Caret, clamp} from './acte-ui';

/**
 * VSheet — feuille letterpress adaptée au cadre 1080 vertical.
 * Largeur ~940 px (vs 1320 en 16:9) pour laisser des marges latérales.
 * Même structure : cadre d'encre, bandeau fleuron + contexte, corps.
 */
export const VSheet = ({
    frame,
    from,
    label,
    height,
    rise = 22,
    children,
}: {
    frame: number;
    from: number;
    label: string;
    height: number;
    /** Durée de la montée d'encre — court (≈14) après un cut net pour éviter le trou. */
    rise?: number;
    children: React.ReactNode;
}) => (
    <div style={{...inkRise(frame, from, rise), width: 940}}>
        <div
            style={{
                border: `2px solid ${C.ink}`,
                borderRadius: 3,
                backgroundColor: C.paperCard,
                // Ombre plus marquée car fond plein papier derrière
                boxShadow: `inset 0 2px 0 rgba(255,255,255,0.6), 8px 12px 0 rgba(26,22,19,0.12)`,
                overflow: 'hidden',
            }}
        >
            {/* Bandeau supérieur : fleuron SVG + label contexte */}
            <div
                style={{
                    display: 'flex',
                    alignItems: 'center',
                    gap: 18,
                    padding: '12px 26px',
                    borderBottom: `1px solid rgba(26,22,19,0.5)`,
                    backgroundColor: C.paperDeep,
                }}
            >
                <svg width={32} height={22} viewBox="0 0 20 14">
                    <path d="M2 7 Q10 0 18 7" fill="none" stroke={C.rouge} strokeWidth={1.1} />
                    <circle cx={10} cy={7} r={1.2} fill={C.rouge} />
                </svg>
                {/* Label contextuel : Mail · Signal · etc. */}
                <span
                    style={{
                        marginLeft: 'auto',
                        fontFamily: DISPLAY,
                        fontSize: 18,
                        letterSpacing: '0.16em',
                        textTransform: 'uppercase',
                        color: C.rouge,
                        border: `1.5px solid ${C.rouge}`,
                        borderRadius: 2,
                        padding: '4px 14px',
                    }}
                >
                    {label}
                </span>
            </div>
            <div style={{position: 'relative', height}}>{children}</div>
        </div>
    </div>
);

/**
 * TabStamp — le coup de tampon letterpress rouge quand on accepte le ghost.
 * Scale 1.35→1 à l'impact (pressAt), ombre qui s'écrase, encre qui se dépose.
 *
 * pressAt = frame global du Tab ; frame = frame global courant.
 */
export const TabStamp = ({
    frame,
    pressAt,
}: {
    frame: number;
    pressAt: number;
}) => {
    const clampOpts = {extrapolateLeft: 'clamp', extrapolateRight: 'clamp'} as const;

    // Apparition avant le coup : le tampon descend légèrement
    const appear = interpolate(frame, [pressAt - 20, pressAt - 6], [0, 1], {
        easing: settleSlow,
        ...clampOpts,
    });

    // À l'impact : scale 1.35→1 (écrasement du tampon)
    const impactScale = interpolate(
        frame,
        [pressAt - 2, pressAt, pressAt + 3, pressAt + 14],
        [1, 1.35, 1.0, 1.0],
        {easing: settle, ...clampOpts},
    );

    // Ombre qui s'écrase à l'impact puis se stabilise
    const shadow = interpolate(
        frame,
        [pressAt - 2, pressAt, pressAt + 5],
        [6, 1, 4],
        clampOpts,
    );

    // Ink-splat : léger halo rouge qui s'estompe après l'impact
    const splatOp = interpolate(
        frame,
        [pressAt, pressAt + 2, pressAt + 22],
        [0, 0.22, 0],
        clampOpts,
    );

    if (frame < pressAt - 20) return null;

    return (
        <div
            style={{
                position: 'relative',
                display: 'inline-flex',
                alignItems: 'center',
                justifyContent: 'center',
                opacity: appear,
            }}
        >
            {/* Halo ink-splat : cercle rouge qui s'estompe à l'impact */}
            <div
                style={{
                    position: 'absolute',
                    width: 180,
                    height: 180,
                    borderRadius: '50%',
                    backgroundColor: C.rouge,
                    opacity: splatOp,
                    pointerEvents: 'none',
                }}
            />
            {/* Le tampon Tab lui-même : Bodoni gros corps */}
            <span
                style={{
                    fontFamily: DISPLAY,
                    fontWeight: 700,
                    fontSize: 92,
                    letterSpacing: '0.04em',
                    color: C.rouge,
                    border: `4px solid ${C.rouge}`,
                    borderRadius: 6,
                    padding: '8px 32px',
                    backgroundColor: C.paper,
                    boxShadow: `${shadow}px ${shadow}px 0 ${C.rougeDeep}`,
                    transform: `scale(${impactScale})`,
                    display: 'block',
                    position: 'relative',
                    zIndex: 1,
                }}
            >
                Tab
            </span>
        </div>
    );
};

/**
 * Tally — compteur « frappes épargnées » façon compteur de taxi.
 * Chaque chiffre est une colonne 0–9 ; translateY positionne le chiffre courant.
 * Le roulement est piloté depuis l'extérieur via `saved` interpolé (settle).
 *
 * visible : opacité globale 0→1 pour l'entrée progressive.
 */
export const Tally = ({
    saved,
    visible,
}: {
    saved: number;
    visible: number;
}) => {
    // On affiche au minimum 3 chiffres pour que le cadre ne change pas de taille
    const maxDigits = Math.max(3, String(saved).length);
    const digits = String(saved).padStart(maxDigits, '0').split('');

    // Hauteur d'une cellule chiffre — fontSize 38, lineHeight 1 = 38 px
    const cellH = 44;

    return (
        <div
            style={{
                display: 'inline-flex',
                alignItems: 'center',
                gap: 14,
                opacity: visible,
            }}
        >
            {/* Compteur roulant */}
            <div
                style={{
                    display: 'flex',
                    alignItems: 'center',
                    gap: 1,
                    backgroundColor: C.paperDeep,
                    border: `1.5px solid ${C.ink}`,
                    borderRadius: 4,
                    padding: '2px 10px',
                    overflow: 'hidden',
                    height: cellH + 4,
                }}
            >
                {digits.map((d, i) => {
                    const digit = parseInt(d, 10);
                    // translateY cible : -digit * cellH amène le bon chiffre dans la fenêtre
                    const ty = -digit * cellH;

                    return (
                        <div
                            key={i}
                            style={{
                                height: cellH,
                                overflow: 'hidden',
                                width: 28,
                            }}
                        >
                            {/* Bande des 10 chiffres — translateY la fait défiler */}
                            <div style={{transform: `translateY(${ty}px)`}}>
                                {[0, 1, 2, 3, 4, 5, 6, 7, 8, 9].map((n) => (
                                    <div
                                        key={n}
                                        style={{
                                            height: cellH,
                                            display: 'flex',
                                            alignItems: 'center',
                                            justifyContent: 'center',
                                            fontFamily: DISPLAY,
                                            fontWeight: 700,
                                            fontSize: 36,
                                            color: C.rouge,
                                            lineHeight: 1,
                                        }}
                                    >
                                        {n}
                                    </div>
                                ))}
                            </div>
                        </div>
                    );
                })}
            </div>
            {/* Légende à droite */}
            <span
                style={{
                    fontFamily: BODY,
                    fontStyle: 'italic',
                    fontSize: 24,
                    color: C.inkSoft,
                    whiteSpace: 'nowrap',
                }}
            >
                frappes épargnées
            </span>
        </div>
    );
};
