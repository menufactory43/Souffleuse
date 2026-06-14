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
 * « Screencast » — la VRAIE capture Cap du ghost (souffleuse-bonjour.mp4), zoomée
 * sur la ligne de texte et jouée une fois, tronquée avant la fin morte.
 *
 * Capture : bande 2160×300, fenêtre TextEdit (police par défaut → ghost = même
 * taille que le texte). On tape « Bonjour, je suis en train de taper un message
 * pour mon application », le ghost ROUGE « cation et je ne sais pas comment faire »
 * apparaît, Tab accepte « application ». Le contenu n'occupe que la moitié gauche
 * de la bande → on crope dessus (= zoom) pour qu'il remplisse le cadre.
 *
 * Pas de pan, pas de boucle : on zoome (FOCUS), on lit en continu, on coupe les
 * ~4 dernières secondes (curseur figé) via SCREENCAST_FRAMES.
 */

const SRC = 'souffleuse-bonjour.mp4';
const SRC_W = 2160;
const SRC_H = 300;
const START_FROM = 30; // ~1 s : saute le blanc de lancement
export const SCREENCAST_FRAMES = 570; // ~19 s joués (≈1→20 s) ; on coupe la fin morte 20-24 s
export const SCREENCAST_SQUARE_FRAMES = SCREENCAST_FRAMES;

// Zone cropée (px source) : toute la ligne de texte, vide de droite/bas exclu.
// Crop serré = zoom : le texte remplit la largeur au lieu de flotter dans la bande.
const FOCUS = {x: 0, y: 0, w: 1160, h: 108};

// La carte occupe cette part de la largeur du canevas (le reste = marge papier).
const CARD_FILL = 0.96;

export const Screencast = () => {
    const f = useCurrentFrame();
    const {width: W, height: H} = useVideoConfig();
    const portrait = H > W; // portrait (4:5 ET 9:16) → mise en page mobile ; sinon paysage 16:9

    // Push-in très léger sur toute la durée : un soupçon de vie, sans pan.
    const push = interpolate(f, [0, SCREENCAST_FRAMES], [1, 1.04], {easing: settle, ...clamp});

    const cardW = W * CARD_FILL * push;
    const scale = cardW / FOCUS.w; // remplit la largeur de carte avec la ligne
    const cardH = FOCUS.h * scale;
    const left = (W - cardW) / 2;
    const top = portrait ? H * 0.42 - cardH / 2 : (H - cardH) / 2;

    const fade = sceneFade(f, SCREENCAST_FRAMES, 12, 16);

    return (
        <AbsoluteFill style={{backgroundColor: C.paper, overflow: 'hidden'}}>
            {/* Musique : J.S. Bach — Prélude en Do BWV 846 (Kevin MacLeod, CC-BY).
                Pas de clic de frappe ni de note de Tab — juste le morceau, fondu enchaîné. */}
            <Audio
                src={staticFile('son-screencast-bach.wav')}
                volume={(af) =>
                    interpolate(af, [0, 30, 510, SCREENCAST_FRAMES], [0, 0.9, 0.9, 0], {
                        extrapolateLeft: 'clamp',
                        extrapolateRight: 'clamp',
                    })
                }
            />

            {/* Hook burné : en muet, dit ce qu'on regarde. */}
            <p
                style={{
                    position: 'absolute',
                    top: portrait ? '14%' : 56,
                    left: 0,
                    right: 0,
                    textAlign: 'center',
                    fontFamily: DISPLAY,
                    fontWeight: 700,
                    fontSize: portrait ? 58 : 50,
                    lineHeight: 1.15,
                    letterSpacing: '-0.01em',
                    color: C.ink,
                    margin: 0,
                    padding: '0 6%',
                }}
            >
                Le texte en <span style={{color: C.rouge}}>rouge</span> est prédit.
                <br />
                <span style={{fontSize: portrait ? 40 : 34, color: C.inkSoft, fontWeight: 400, fontStyle: 'italic'}}>
                    Tab pour l'accepter — dans n'importe quelle app.
                </span>
            </p>

            {/* La capture, cropée sur la ligne (= zoom), jouée une fois. */}
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
                    opacity: fade,
                }}
            >
                <OffthreadVideo
                    src={staticFile(SRC)}
                    startFrom={START_FROM}
                    muted
                    style={{
                        position: 'absolute',
                        left: -FOCUS.x * scale,
                        top: -FOCUS.y * scale,
                        width: SRC_W * scale,
                        height: SRC_H * scale,
                        filter: 'contrast(1.06) saturate(1.05)',
                    }}
                />
            </div>

            {/* Wordmark + URL, en bas. */}
            <div
                style={{
                    position: 'absolute',
                    bottom: portrait ? '10%' : 56,
                    left: 0,
                    right: 0,
                    textAlign: 'center',
                }}
            >
                <span
                    style={{
                        fontFamily: DISPLAY,
                        fontWeight: 700,
                        fontSize: portrait ? 52 : 44,
                        letterSpacing: '0.06em',
                        color: C.rouge,
                    }}
                >
                    Souffleuse
                </span>
                <div
                    style={{
                        fontFamily: BODY,
                        fontSize: portrait ? 32 : 28,
                        color: C.inkFaint,
                        marginTop: 6,
                    }}
                >
                    souffleuse.app · 100% local · gratuit
                </div>
            </div>

            <Grain />
        </AbsoluteFill>
    );
};
