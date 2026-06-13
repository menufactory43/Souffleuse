import {AbsoluteFill, OffthreadVideo, Sequence, interpolate, staticFile, useCurrentFrame} from 'remotion';
import {C, BODY, DISPLAY} from '../theme';
import {inkRise} from '../helpers';
import {Grain} from '../Paper';

/**
 * Montage des VRAIES captures du ghost (produites par scripts/capture-ghost.sh).
 * Chaque clip .mov de public/clips/ est posé dans le cadre Livret, avec sa
 * légende d'app. Tant que les clips n'existent pas, cette composition affiche
 * une consigne au lieu de planter.
 *
 * Pour activer : capturez les clips, vérifiez que les noms correspondent à
 * CLIPS ci-dessous, puis (si pas déjà fait) décommentez la composition
 * SouffleuseCaptures dans Root.tsx.
 */
const clamp = {extrapolateLeft: 'clamp', extrapolateRight: 'clamp'} as const;

// Doivent correspondre aux .mov écrits par capture-ghost.sh (slug = app en
// minuscules, espaces → tirets). Réglez `from`/`len` selon vos prises.
export type Clip = {file: string; app: string; contexte: string; len: number; from?: number};
export const CLIPS: Clip[] = [
    {file: 'clips/souffle-merci.mov', app: 'Un remerciement', contexte: 'en deux mots', len: 170, from: 60},
    {file: 'clips/souffle-journee.mov', app: 'Un mot pour finir', contexte: 'à la fin d’un message', len: 170, from: 60},
    {file: 'clips/souffle-signature.mov', app: 'Une signature', contexte: 'pour conclure', len: 170, from: 60},
];

const SLOT = 170; // durée d'un clip à l'écran (frames) — léger chevauchement de fondu
export const CAPTURES_FRAMES = CLIPS.length * SLOT + 30;

const ClipCard = ({clip}: {clip: Clip}) => {
    const frame = useCurrentFrame();
    const op = interpolate(frame, [0, 10, SLOT - 12, SLOT], [0, 1, 1, 0], clamp);
    return (
        <AbsoluteFill style={{justifyContent: 'center', alignItems: 'center', opacity: op}}>
            <div style={{...inkRise(frame, 0, 14), width: 1320}}>
                <p
                    style={{
                        fontFamily: DISPLAY,
                        fontSize: 22,
                        letterSpacing: '0.2em',
                        textTransform: 'uppercase',
                        color: C.inkFaint,
                        margin: '0 0 16px',
                    }}
                >
                    <b style={{color: C.rouge, fontWeight: 700}}>{clip.app} :</b> {clip.contexte}
                </p>
                {/* Bande large au ratio natif de la capture (1180×320 ≈ 3,7:1) :
                    une ligne de texte réelle, sans rognage ni bord noir. */}
                <div
                    style={{
                        border: `2px solid ${C.ink}`,
                        borderRadius: 3,
                        backgroundColor: C.paperCard,
                        boxShadow: `inset 0 2px 0 rgba(255,255,255,0.6), 10px 14px 0 rgba(26,22,19,0.10)`,
                        overflow: 'hidden',
                        aspectRatio: '1180 / 170',
                    }}
                >
                    {/* multiply : le blanc de la capture s'efface, le texte reste sur le papier */}
                    <OffthreadVideo
                        src={staticFile(clip.file)}
                        startFrom={clip.from ?? 0}
                        style={{width: '100%', height: '100%', objectFit: 'cover', objectPosition: 'center top', mixBlendMode: 'multiply'}}
                    />
                </div>
            </div>
        </AbsoluteFill>
    );
};

export const Captures = () => {
    return (
        <AbsoluteFill style={{backgroundColor: C.paper, fontFamily: BODY}}>
            {CLIPS.map((clip, i) => (
                <Sequence key={i} from={i * SLOT} durationInFrames={SLOT}>
                    <ClipCard clip={clip} />
                </Sequence>
            ))}
            <Grain />
        </AbsoluteFill>
    );
};
