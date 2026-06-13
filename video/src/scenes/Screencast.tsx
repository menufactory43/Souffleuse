import {
    AbsoluteFill,
    Audio,
    interpolate,
    OffthreadVideo,
    staticFile,
    useCurrentFrame,
    useVideoConfig,
} from 'remotion';
import {C, BODY, DISPLAY} from '../theme';
import {settle, sceneFade} from '../helpers';
import {clamp} from './acte-ui';
import {Grain} from '../Paper';

/**
 * « Screencast » — recrée le ZOOM-AUTO (façon Cap/Screen Studio) par-dessus une
 * VRAIE capture de Souffleuse, en pur Remotion. Aucun GUI : zoom/pan keyframé
 * vers la zone de texte (le caret), cadre flottant arrondi + ombre, fond papier.
 * Reproductible pour toute capture : régler SRC + START_FROM + FOCUS.
 *
 * Source : public/souffleuse-reel.mp4 (vraie capture Cap, fenêtre TextEdit,
 * 1920×768, 60 fps). On entre après la frappe de « Merci » ; le ghost rouge
 * « pour votre aide. » apparaît puis se valide au Tab, mot à mot.
 *
 * Rendu en vertical (1080×1920) ET 16:9 (1920×1080) via useVideoConfig.
 */
export const SCREENCAST_FRAMES = 150; // 5 s @30fps

const SRC = 'souffleuse-reel.mp4';
const SRC_ASPECT = 768 / 1920; // hauteur/largeur de la capture
const START_FROM = 75; // démarre la source à ~2,5 s (fin de frappe « Bonjour… »)

// La carte occupe cette fraction de la largeur du canevas (le reste = marge papier).
const CARD_W_FRAC = {h: 0.9, v: 0.86};
// On ne garde que le bandeau du haut de la fenêtre (barre de titre + toolbar +
// la ligne de texte) : sinon la carte est immense pour une seule ligne.
const BAND_FRAC = 0.34;

export const Screencast = () => {
    const f = useCurrentFrame();
    const {width: W, height: H} = useVideoConfig();
    const vertical = H > W;

    // Carte CONTENUE : la fenêtre entière tient dans le cadre (4 coins arrondis
    // visibles), centrée, avec un léger push-in — elle ne déborde jamais du canevas.
    const push = interpolate(f, [0, 25, SCREENCAST_FRAMES], [1, 1, 1.05], {easing: settle, ...clamp});
    const cardW = W * (vertical ? CARD_W_FRAC.v : CARD_W_FRAC.h) * push;
    const fullVideoH = cardW * SRC_ASPECT; // hauteur réelle de la fenêtre
    const cardH = fullVideoH * BAND_FRAC; // carte = bandeau du haut seulement
    const left = (W - cardW) / 2;
    const top = vertical ? H * 0.32 : (H - cardH) / 2;

    const fade = sceneFade(f, SCREENCAST_FRAMES, 8, 14);

    return (
        <AbsoluteFill style={{backgroundColor: C.paper, overflow: 'hidden', opacity: fade}}>
            {/* Clics de frappe + souffle synchronisés (make-bande-son-screencast.mjs) */}
            <Audio src={staticFile('son-screencast.wav')} />
            {/* La capture, flottante : coins arrondis + ombre (visibles quand large) */}
            <div
                style={{
                    position: 'absolute',
                    left,
                    top,
                    width: cardW,
                    height: cardH,
                    borderRadius: 16,
                    overflow: 'hidden',
                    boxShadow: '0 30px 90px rgba(26,22,19,0.30)',
                    border: '1px solid rgba(26,22,19,0.14)',
                }}
            >
                <OffthreadVideo
                    src={staticFile(SRC)}
                    startFrom={START_FROM}
                    muted
                    style={{
                        position: 'absolute',
                        top: 0,
                        left: 0,
                        width: '100%',
                        height: fullVideoH, // hauteur réelle : seul le bandeau du haut est visible
                        objectFit: 'fill',
                        // agrandissement symétrique ancré en haut : masque la fine ligne
                        // de cadre gauche sans bouger le bandeau.
                        transform: 'scale(1.012)',
                        transformOrigin: 'top center',
                    }}
                />
            </div>

            {/* Légende discrète */}
            {vertical && (
                <p
                    style={{
                        position: 'absolute',
                        bottom: '13%',
                        left: 0,
                        right: 0,
                        textAlign: 'center',
                        fontFamily: BODY,
                        fontStyle: 'italic',
                        fontSize: 40,
                        color: C.inkSoft,
                        margin: 0,
                        opacity: interpolate(f, [60, 76], [0, 1], clamp),
                    }}
                >
                    Le ghost. En vrai.
                </p>
            )}
            <span
                style={{
                    position: 'absolute',
                    bottom: vertical ? 60 : 40,
                    right: vertical ? 0 : 48,
                    left: vertical ? 0 : 'auto',
                    textAlign: 'center',
                    fontFamily: DISPLAY,
                    fontWeight: 700,
                    fontSize: vertical ? 40 : 34,
                    letterSpacing: '0.06em',
                    color: C.rouge,
                    opacity: interpolate(f, [SCREENCAST_FRAMES - 40, SCREENCAST_FRAMES - 26], [0, 1], clamp),
                }}
            >
                Souffleuse
            </span>

            <Grain />
        </AbsoluteFill>
    );
};
