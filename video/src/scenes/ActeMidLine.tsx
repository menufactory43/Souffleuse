import {AbsoluteFill, interpolate, random, useCurrentFrame} from 'remotion';
import {C, BODY} from '../theme';
import {sceneFade, settle} from '../helpers';
import {ActeCard, Caret, Contexte, HintRow, Sheet, clamp} from './acte-ui';

/**
 * Acte II — la complétion en plein milieu : le curseur revient DANS une
 * phrase déjà écrite ; le souffle ne peut plus se poser en ligne (il
 * recouvrirait la suite), alors il flotte en pastille SOUS la ligne, ancrée
 * au caret. Tab insère au caret, la suite de la phrase s'écarte d'elle-même.
 */
const BASE = 'Merci Claire pour votre retour. À mardi pour le point.';
const CARET_TARGET = 31; // juste après « retour. »
const INS = ' Je vous envoie';
const GHOST = " le devis corrigé d'ici jeudi.";

// Partition locale — la bande-son est calée sur PILL_AT et PRESS.
const TRAVEL = [80, 104] as const; // le caret remonte la ligne (←, touche répétée)
const TYPE_FROM = 118;
export const PILL_AT = 156;
export const PRESS = 208;

const TIMES: number[] = (() => {
    const times: number[] = [];
    let t = TYPE_FROM;
    for (let i = 0; i < INS.length; i++) {
        t += 2.0 + random(`midline-frappe-${i}`) * 0.9;
        times.push(t);
    }
    return times;
})();

export const ActeMidLine = ({duration}: {duration: number}) => {
    const frame = useCurrentFrame();

    // Le caret : posé en fin de phrase, puis il remonte au milieu, pas à pas.
    const caretIdx = Math.round(
        interpolate(frame, [TRAVEL[0], TRAVEL[1]], [BASE.length, CARET_TARGET], {easing: settle, ...clamp}),
    );
    const shown = TIMES.filter((t) => t <= frame).length;
    const accepted = frame >= PRESS;

    const left = BASE.slice(0, caretIdx) + INS.slice(0, shown) + (accepted ? GHOST : '');
    const right = BASE.slice(caretIdx);

    const press = interpolate(frame, [PRESS - 3, PRESS, PRESS + 4], [0, 1, 0], clamp);
    const flash = interpolate(frame, [PRESS, PRESS + 2, PRESS + 24], [0, 0.3, 0], clamp);

    // La pastille : entrée à l'encre, puis envol vers la ligne quand Tab la prend.
    const pillIn = interpolate(frame, [PILL_AT, PILL_AT + 16], [0, 1], {easing: settle, ...clamp});
    const pillOut = interpolate(frame, [PRESS, PRESS + 9], [0, 1], {easing: settle, ...clamp});
    const pillOn = frame >= PILL_AT && frame < PRESS + 9;

    const travelNote = interpolate(frame, [TRAVEL[0] + 4, TRAVEL[0] + 14, TYPE_FROM + 20, TYPE_FROM + 32], [0, 1, 1, 0], clamp);
    const closing = interpolate(frame, [244, 264], [0, 1], clamp);

    return (
        <AbsoluteFill
            style={{justifyContent: 'center', alignItems: 'center', opacity: sceneFade(frame, duration, 8, 14)}}
        >
            <ActeCard
                frame={frame}
                numero="Acte II"
                titre="En plein milieu"
                didascalie="(on revient sur une réplique déjà dite)"
            />
            {frame > 46 ? (
                <>
                    <Sheet frame={frame} from={50} acte="Acte II" height={420}>
                        <div style={{position: 'absolute', inset: '52px 56px 0'}}>
                            <Contexte label="Mail · relecture du brouillon" />
                            <p style={{fontFamily: BODY, fontSize: 38, lineHeight: 1.65, color: C.ink, margin: 0}}>
                                <span style={{whiteSpace: 'pre-wrap'}}>{BASE.slice(0, caretIdx)}</span>
                                <span
                                    style={{
                                        whiteSpace: 'pre-wrap',
                                        backgroundColor: `rgba(168,154,130,${flash})`,
                                        borderRadius: 4,
                                    }}
                                >
                                    {INS.slice(0, shown) + (accepted ? GHOST : '')}
                                </span>
                                {/* L'ancre : un span relatif de largeur nulle au caret — la
                                    pastille s'y accroche en absolu, exactement sous la ligne. */}
                                <span style={{position: 'relative'}}>
                                    <Caret frame={frame} />
                                    {pillOn ? (
                                        <span
                                            style={{
                                                position: 'absolute',
                                                top: '1.32em',
                                                left: -8,
                                                zIndex: 2,
                                                whiteSpace: 'nowrap',
                                                fontFamily: BODY,
                                                fontStyle: 'italic',
                                                fontSize: 32,
                                                color: C.ghost,
                                                backgroundColor: C.paperCard,
                                                border: `1.5px solid ${C.ink}`,
                                                borderRadius: 5,
                                                padding: '4px 18px 6px',
                                                boxShadow: '5px 6px 0 rgba(26,22,19,0.12)',
                                                opacity: pillIn * (1 - pillOut),
                                                filter: `blur(${(1 - pillIn) * 6}px)`,
                                                transform: `translateY(${(1 - pillIn) * 10 - pillOut * 16}px)`,
                                            }}
                                        >
                                            <span
                                                style={{
                                                    position: 'absolute',
                                                    top: -7,
                                                    left: 14,
                                                    width: 11,
                                                    height: 11,
                                                    transform: 'rotate(45deg)',
                                                    backgroundColor: C.paperCard,
                                                    borderTop: `1.5px solid ${C.ink}`,
                                                    borderLeft: `1.5px solid ${C.ink}`,
                                                }}
                                            />
                                            {GHOST.trim()}
                                        </span>
                                    ) : null}
                                </span>
                                <span style={{whiteSpace: 'pre-wrap'}}>{right}</span>
                            </p>
                            <p
                                style={{
                                    fontFamily: BODY,
                                    fontStyle: 'italic',
                                    fontSize: 27,
                                    color: C.inkFaint,
                                    margin: '16px 0 0 6px',
                                    opacity: travelNote,
                                }}
                            >
                                (le curseur revient au milieu de la réplique — le souffleur suit)
                            </p>
                            <HintRow
                                opacity={interpolate(frame, [PILL_AT + 12, PILL_AT + 28], [0, 1], clamp)}
                                press={press}
                                tabLit={frame >= PILL_AT + 18 && frame < PRESS + 14}
                                tabLabel="pour insérer au caret"
                            />
                        </div>
                    </Sheet>
                    <p
                        style={{
                            fontFamily: BODY,
                            fontStyle: 'italic',
                            fontSize: 32,
                            color: C.inkSoft,
                            marginTop: 30,
                            opacity: closing,
                        }}
                    >
                        Même au milieu d'une phrase — la suite s'écarte, le souffle se glisse.
                    </p>
                </>
            ) : null}
        </AbsoluteFill>
    );
};
