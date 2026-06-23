import {
  AbsoluteFill,
  Audio,
  interpolate,
  interpolateColors,
  spring,
  staticFile,
  useCurrentFrame,
  useVideoConfig,
} from 'remotion';
import {BRAND} from './brand';
import {useBrandFonts} from './useBrandFonts';

// Mettre à true une fois le fichier déposé dans public/audio/score.mp3
// (enregistrement domaine public / libre de droits — voir README).
const HAS_MUSIC = true;
const MUSIC_FILE = 'audio/score.mp3';

const TYPED = 'Merci pour votre retour, je revi';
const GHOST = 'ens vers vous dès demain matin.';

// Petite enveloppe fondu entrée/sortie réutilisable.
const band = (frame: number, inAt: number, outAt: number, dur = 12) =>
  interpolate(
    frame,
    [inAt, inAt + dur, outAt - dur, outAt],
    [0, 1, 1, 0],
    {extrapolateLeft: 'clamp', extrapolateRight: 'clamp'},
  );

const Caption: React.FC<{frame: number; inAt: number; outAt: number; children: React.ReactNode}> = ({
  frame,
  inAt,
  outAt,
  children,
}) => {
  const o = band(frame, inAt, outAt);
  const y = interpolate(o, [0, 1], [14, 0]);
  return (
    <div
      style={{
        position: 'absolute',
        left: 0,
        right: 0,
        bottom: 360,
        textAlign: 'center',
        opacity: o,
        transform: `translateY(${y}px)`,
        fontFamily: BRAND.body,
        fontWeight: 500,
        fontSize: 46,
        color: BRAND.ink,
        padding: '0 90px',
        lineHeight: 1.3,
      }}
    >
      {children}
    </div>
  );
};

export const MagicMoment: React.FC = () => {
  useBrandFonts();
  const frame = useCurrentFrame();
  const {fps, durationInFrames} = useVideoConfig();

  // Intro de la carte de composition.
  const cardIn = spring({frame: frame - 8, fps, config: {damping: 200}});
  const cardOpacity = interpolate(frame, [0, 18], [0, 1], {extrapolateRight: 'clamp'});

  // Frappe lettre par lettre.
  const typedCount = Math.max(
    0,
    Math.min(TYPED.length, Math.floor(interpolate(frame, [28, 150], [0, TYPED.length]))),
  );
  const typedVisible = TYPED.slice(0, typedCount);
  const typingDone = typedCount >= TYPED.length;

  // Apparition du souffle (gris), légère montée + dé-flou.
  const ghostOpacity = interpolate(frame, [150, 176], [0, 1], {
    extrapolateLeft: 'clamp',
    extrapolateRight: 'clamp',
  });
  const ghostBlur = interpolate(frame, [150, 176], [7, 0], {
    extrapolateLeft: 'clamp',
    extrapolateRight: 'clamp',
  });
  // Respiration du souffle pendant la tenue.
  const breathe =
    frame > 176 && frame < 240 ? 0.86 + 0.14 * (0.5 + 0.5 * Math.sin((frame - 176) / 7)) : 1;

  // Le souffle vire de l'encre-gris à l'encre pleine quand on accepte.
  const ghostColor = interpolateColors(frame, [244, 262], [BRAND.ghost, BRAND.ink]);
  const accepted = frame >= 256;

  // Touche Tab : apparition puis pression ressort.
  const tabIn = interpolate(frame, [206, 224], [0, 1], {
    extrapolateLeft: 'clamp',
    extrapolateRight: 'clamp',
  });
  const press = spring({frame: frame - 238, fps, config: {damping: 12, mass: 0.4}});
  const tabScale = 1 - 0.12 * press * (frame < 252 ? 1 : interpolate(frame, [252, 268], [1, 0], {extrapolateRight: 'clamp'}));
  const tabGlow = band(frame, 236, 270, 8);

  // Balayage de surbrillance au moment de l'acceptation.
  const sweep = band(frame, 244, 268, 6);

  // Caret clignotant tant qu'on tape / qu'on tient, puis il s'efface.
  const caretBlink = frame % 30 < 15 ? 1 : 0;
  const caretFade = interpolate(frame, [250, 262], [1, 0], {
    extrapolateLeft: 'clamp',
    extrapolateRight: 'clamp',
  });
  const caretOpacity = (typingDone && frame < 176 ? caretBlink : frame < 176 ? 1 : caretBlink) * caretFade;

  // Carte d'attaque qui s'efface pour laisser place au carton final.
  const stageOut = interpolate(frame, [392, 412], [1, 0.0], {
    extrapolateLeft: 'clamp',
    extrapolateRight: 'clamp',
  });
  const endIn = band(frame, 398, durationInFrames + 30, 16);

  return (
    <AbsoluteFill style={{backgroundColor: BRAND.paper, overflow: 'hidden'}}>
      {/* Musique classique, en sourdine (« à voix basse ») : fondu d'entrée/sortie. */}
      {HAS_MUSIC ? (
        <Audio
          src={staticFile(MUSIC_FILE)}
          volume={(f) =>
            interpolate(
              f,
              [0, 18, durationInFrames - 36, durationInFrames],
              [0, 0.42, 0.42, 0],
              {extrapolateLeft: 'clamp', extrapolateRight: 'clamp'},
            )
          }
        />
      ) : null}

      {/* Vignette douce */}
      <AbsoluteFill
        style={{
          background:
            'radial-gradient(120% 80% at 50% 38%, rgba(0,0,0,0) 55%, rgba(26,22,19,0.10) 100%)',
        }}
      />

      {/* Scène (carte de composition) */}
      <AbsoluteFill style={{opacity: stageOut}}>
        {/* Wordmark */}
        <div
          style={{
            position: 'absolute',
            top: 120,
            left: 0,
            right: 0,
            textAlign: 'center',
            opacity: cardOpacity,
            fontFamily: BRAND.display,
            fontWeight: 700,
            fontSize: 40,
            letterSpacing: 14,
            textTransform: 'uppercase',
            color: BRAND.ink,
          }}
        >
          Souffleuse
        </div>
        <div
          style={{
            position: 'absolute',
            top: 182,
            left: 0,
            right: 0,
            textAlign: 'center',
            opacity: cardOpacity * 0.7,
            fontFamily: BRAND.body,
            fontStyle: 'italic',
            fontSize: 28,
            color: BRAND.ghost,
          }}
        >
          — elle attend que la phrase se dérobe.
        </div>

        {/* Carte */}
        <div
          style={{
            position: 'absolute',
            top: 520,
            left: 90,
            right: 90,
            transform: `translateY(${interpolate(cardIn, [0, 1], [40, 0])}px)`,
            opacity: cardOpacity,
            background: '#fbf5e8',
            border: `2px solid ${BRAND.paperDark}`,
            borderRadius: 28,
            boxShadow: '0 30px 70px rgba(26,22,19,0.16)',
            padding: '46px 50px 56px',
          }}
        >
          {/* En-tête du message */}
          <div
            style={{
              fontFamily: BRAND.body,
              fontSize: 30,
              color: BRAND.ghost,
              borderBottom: `1px solid ${BRAND.paperDark}`,
              paddingBottom: 22,
              marginBottom: 30,
              display: 'flex',
              justifyContent: 'space-between',
            }}
          >
            <span>À : Camille</span>
            <span style={{fontStyle: 'italic'}}>Nouveau message</span>
          </div>

          {/* Corps : tapé (encre) + souffle (gris) + caret */}
          <div
            style={{
              fontFamily: BRAND.body,
              fontWeight: 400,
              fontSize: 50,
              lineHeight: 1.5,
              color: BRAND.ink,
              minHeight: 230,
            }}
          >
            <span style={{position: 'relative'}}>
              {/* balayage de surbrillance à l'acceptation */}
              <span
                style={{
                  position: 'absolute',
                  left: -6,
                  right: -6,
                  top: 4,
                  bottom: 4,
                  background: BRAND.rouge,
                  opacity: sweep * 0.12,
                  borderRadius: 8,
                }}
              />
              {typedVisible}
              <span
                style={{
                  color: ghostColor,
                  opacity: ghostOpacity * (accepted ? 1 : breathe),
                  filter: `blur(${ghostBlur}px)`,
                }}
              >
                {ghostOpacity > 0 ? GHOST : ''}
              </span>
              {/* caret */}
              <span
                style={{
                  display: 'inline-block',
                  width: 4,
                  height: 50,
                  marginLeft: 3,
                  transform: 'translateY(10px)',
                  background: BRAND.ink,
                  opacity: caretOpacity,
                }}
              />
            </span>
          </div>
        </div>

        {/* Touche Tab */}
        <div
          style={{
            position: 'absolute',
            left: 0,
            right: 0,
            bottom: 470,
            display: 'flex',
            justifyContent: 'center',
            alignItems: 'center',
            gap: 22,
            opacity: tabIn,
          }}
        >
          <div
            style={{
              fontFamily: BRAND.body,
              fontSize: 38,
              fontWeight: 500,
              minWidth: 150,
              textAlign: 'center',
              padding: '14px 26px',
              color: BRAND.ink,
              background: '#fbf5e8',
              border: `2px solid ${BRAND.ink}`,
              borderRadius: 16,
              transform: `scale(${tabScale})`,
              boxShadow: `0 0 ${30 * tabGlow}px rgba(140,43,33,${0.55 * tabGlow})`,
            }}
          >
            ⇥ Tab
          </div>
          <span style={{fontFamily: BRAND.body, fontStyle: 'italic', fontSize: 34, color: BRAND.ghost}}>
            pour accepter
          </span>
        </div>

        {/* Légendes successives */}
        <Caption frame={frame} inAt={180} outAt={236}>
          La suite, déjà là — soufflée en gris.
        </Caption>
        <Caption frame={frame} inAt={266} outAt={330}>
          Tab pour la prendre. Esc pour l'oublier.
        </Caption>
        <Caption frame={frame} inAt={335} outAt={392}>
          Pas de cloud. 100&nbsp;% sur ton Mac.
        </Caption>
      </AbsoluteFill>

      {/* Carton final */}
      <AbsoluteFill
        style={{
          opacity: endIn,
          justifyContent: 'center',
          alignItems: 'center',
          padding: '0 110px',
          textAlign: 'center',
        }}
      >
        <div
          style={{
            fontFamily: BRAND.display,
            fontWeight: 900,
            fontSize: 86,
            lineHeight: 1.12,
            color: BRAND.ink,
          }}
        >
          Le mot juste,
          <br />
          soufflé à voix basse.
        </div>
        <div
          style={{
            width: 120,
            height: 4,
            background: BRAND.rouge,
            margin: '46px auto 40px',
          }}
        />
        <div
          style={{
            fontFamily: BRAND.body,
            fontWeight: 500,
            fontSize: 50,
            letterSpacing: 1,
            color: BRAND.rouge,
          }}
        >
          souffleuse.app
        </div>
        <div
          style={{
            marginTop: 26,
            fontFamily: BRAND.body,
            fontStyle: 'italic',
            fontSize: 32,
            color: BRAND.ghost,
          }}
        >
          100&nbsp;% local · gratuit pendant la bêta
        </div>
      </AbsoluteFill>
    </AbsoluteFill>
  );
};
