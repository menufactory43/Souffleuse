import {
  AbsoluteFill,
  interpolate,
  spring,
  useCurrentFrame,
  useVideoConfig,
} from 'remotion';
import {BRAND} from './brand';
import {useBrandFonts} from './useBrandFonts';
import {band, Caption, EndCard, Score, Vignette, Wordmark} from './components';

const TYPED = 'Oui, je t’envoie ça demain matin.';
const TRANSLATED = 'Sure, I’ll send it tomorrow morning.';

export const Translation: React.FC = () => {
  useBrandFonts();
  const frame = useCurrentFrame();
  const {fps} = useVideoConfig();

  const intro = interpolate(frame, [0, 18], [0, 1], {extrapolateRight: 'clamp'});
  const cardIn = spring({frame: frame - 18, fps, config: {damping: 200}});
  const cardOpacity = interpolate(frame, [16, 34], [0, 1], {extrapolateLeft: 'clamp', extrapolateRight: 'clamp'});

  // Bulle entrante (anglais).
  const bubbleIn = spring({frame: frame - 48, fps, config: {damping: 200}});

  // Frappe FR.
  const typedCount = Math.max(0, Math.min(TYPED.length, Math.floor(interpolate(frame, [96, 206], [0, TYPED.length]))));
  const typedVisible = TYPED.slice(0, typedCount);
  const typingDone = typedCount >= TYPED.length;

  // HUD de traduction.
  const hudIn = band(frame, 224, 480, 16);
  const hudRise = interpolate(hudIn, [0, 1], [24, 0]);
  const hudBlur = interpolate(frame, [224, 252], [8, 0], {extrapolateLeft: 'clamp', extrapolateRight: 'clamp'});

  const caretBlink = frame % 30 < 15 ? 1 : 0;
  const caretOpacity = typingDone ? caretBlink : 1;

  const stageOut = interpolate(frame, [416, 436], [1, 0], {extrapolateLeft: 'clamp', extrapolateRight: 'clamp'});

  return (
    <AbsoluteFill style={{backgroundColor: BRAND.paper, overflow: 'hidden'}}>
      <Score src="audio/score-arabesque.mp3" />
      <Vignette />

      <AbsoluteFill style={{opacity: stageOut}}>
        <Wordmark opacity={intro} subtitle="— elle change de langue, pas de scène." />

        {/* Carte conversation */}
        <div
          style={{
            position: 'absolute',
            top: 460,
            left: 90,
            right: 90,
            transform: `translateY(${interpolate(cardIn, [0, 1], [40, 0])}px)`,
            opacity: cardOpacity,
            background: '#fbf5e8',
            border: `2px solid ${BRAND.paperDark}`,
            borderRadius: 28,
            boxShadow: '0 30px 70px rgba(26,22,19,0.16)',
            padding: '40px 44px 48px',
          }}
        >
          <div style={{fontFamily: BRAND.body, fontSize: 28, color: BRAND.ghost, marginBottom: 28}}>
            Conversation · Camille
          </div>

          {/* Bulle entrante (EN) */}
          <div
            style={{
              opacity: bubbleIn,
              transform: `translateX(${interpolate(bubbleIn, [0, 1], [-24, 0])}px)`,
              alignSelf: 'flex-start',
              maxWidth: '78%',
              background: BRAND.paperDark,
              borderRadius: '6px 22px 22px 22px',
              padding: '22px 28px',
              fontFamily: BRAND.body,
              fontSize: 42,
              color: BRAND.ink,
              marginBottom: 36,
            }}
          >
            Can you send it before Friday?
          </div>

          {/* Champ de saisie (FR) */}
          <div
            style={{
              border: `2px solid ${BRAND.paperDark}`,
              borderRadius: 18,
              padding: '24px 28px',
              fontFamily: BRAND.body,
              fontSize: 44,
              color: BRAND.ink,
              minHeight: 70,
            }}
          >
            {typedVisible}
            <span style={{display: 'inline-block', width: 4, height: 44, marginLeft: 3, transform: 'translateY(8px)', background: BRAND.ink, opacity: caretOpacity}} />
          </div>
        </div>

        {/* HUD de traduction */}
        <div
          style={{
            position: 'absolute',
            top: 1010,
            left: 130,
            right: 130,
            opacity: hudIn,
            transform: `translateY(${hudRise}px)`,
            filter: `blur(${hudBlur}px)`,
            background: BRAND.ink,
            borderRadius: 22,
            padding: '30px 34px',
            boxShadow: '0 24px 60px rgba(26,22,19,0.28)',
          }}
        >
          <div style={{display: 'flex', justifyContent: 'space-between', alignItems: 'center', marginBottom: 16}}>
            <span style={{fontFamily: BRAND.body, fontStyle: 'italic', fontSize: 28, color: BRAND.paperDark}}>Traduction</span>
            <span style={{fontFamily: BRAND.body, fontWeight: 500, fontSize: 28, color: BRAND.paper, border: `1px solid ${BRAND.ghost}`, borderRadius: 10, padding: '4px 14px'}}>FR → EN</span>
          </div>
          <div style={{fontFamily: BRAND.body, fontSize: 46, color: BRAND.paper, lineHeight: 1.35}}>{TRANSLATED}</div>
        </div>

        <Caption inAt={258} outAt={336} bottom={300}>Une langue par conversation.</Caption>
        <Caption inAt={342} outAt={412} bottom={300}>Traduit en local. Rien n'est envoyé.</Caption>
      </AbsoluteFill>

      <EndCard
        inAt={420}
        title={<>Écris dans ta langue.<br />Sois lu dans la sienne.</>}
        tagline="HUD discret · une langue cible par fil · 100 % local"
      />
    </AbsoluteFill>
  );
};
