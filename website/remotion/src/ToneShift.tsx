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

const CASUAL = 'ok ça marche je gère, je te tiens au jus';
const FORMAL = 'C’est noté, je m’en occupe et je vous tiens informé.';

const Tag: React.FC<{label: string; tone: 'casual' | 'formal'}> = ({label, tone}) => (
  <span
    style={{
      fontFamily: BRAND.body,
      fontWeight: 500,
      fontSize: 28,
      padding: '6px 18px',
      borderRadius: 999,
      color: tone === 'formal' ? BRAND.paper : BRAND.ink,
      background: tone === 'formal' ? BRAND.rouge : BRAND.paperDark,
    }}
  >
    {label}
  </span>
);

export const ToneShift: React.FC = () => {
  useBrandFonts();
  const frame = useCurrentFrame();
  const {fps} = useVideoConfig();

  const intro = interpolate(frame, [0, 18], [0, 1], {extrapolateRight: 'clamp'});

  // Carte Slack + frappe décontractée.
  const slackIn = spring({frame: frame - 22, fps, config: {damping: 200}});
  const slackOpacity = interpolate(frame, [20, 40], [0, 1], {extrapolateLeft: 'clamp', extrapolateRight: 'clamp'});
  const typedCount = Math.max(0, Math.min(CASUAL.length, Math.floor(interpolate(frame, [44, 150], [0, CASUAL.length]))));
  const typedVisible = CASUAL.slice(0, typedCount);
  const typingDone = typedCount >= CASUAL.length;
  const caretBlink = frame % 30 < 15 ? 1 : 0;
  const caretFade = interpolate(frame, [196, 212], [1, 0], {extrapolateLeft: 'clamp', extrapolateRight: 'clamp'});
  const caretOpacity = (typingDone ? caretBlink : 1) * caretFade;

  // Flèche « relecture par ton ».
  const arrowIn = band(frame, 188, 480, 10);

  // Carte Mail + reformulation.
  const mailIn = spring({frame: frame - 210, fps, config: {damping: 200}});
  const mailOpacity = interpolate(frame, [208, 232], [0, 1], {extrapolateLeft: 'clamp', extrapolateRight: 'clamp'});
  const formalIn = interpolate(frame, [236, 268], [0, 1], {extrapolateLeft: 'clamp', extrapolateRight: 'clamp'});
  const formalBlur = interpolate(frame, [236, 268], [6, 0], {extrapolateLeft: 'clamp', extrapolateRight: 'clamp'});

  const stageOut = interpolate(frame, [416, 436], [1, 0], {extrapolateLeft: 'clamp', extrapolateRight: 'clamp'});

  return (
    <AbsoluteFill style={{backgroundColor: BRAND.paper, overflow: 'hidden'}}>
      <Score src="audio/score-gnossienne3.mp3" />
      <Vignette />

      <AbsoluteFill style={{opacity: stageOut}}>
        <Wordmark opacity={intro} subtitle="— elle relit selon la salle." />

        {/* Carte Slack (décontracté) */}
        <div
          style={{
            position: 'absolute',
            top: 440,
            left: 90,
            right: 90,
            transform: `translateY(${interpolate(slackIn, [0, 1], [40, 0])}px)`,
            opacity: slackOpacity,
            background: '#fbf5e8',
            border: `2px solid ${BRAND.paperDark}`,
            borderRadius: 26,
            padding: '34px 40px 40px',
            boxShadow: '0 22px 50px rgba(26,22,19,0.12)',
          }}
        >
          <div style={{marginBottom: 22}}>
            <Tag label="Slack" tone="casual" />
          </div>
          <div style={{fontFamily: BRAND.body, fontSize: 46, lineHeight: 1.45, color: BRAND.ink, minHeight: 130}}>
            {typedVisible}
            <span style={{display: 'inline-block', width: 4, height: 44, marginLeft: 3, transform: 'translateY(8px)', background: BRAND.ink, opacity: caretOpacity}} />
          </div>
        </div>

        {/* Flèche relecture par ton */}
        <div
          style={{
            position: 'absolute',
            top: 760,
            left: 0,
            right: 0,
            textAlign: 'center',
            opacity: arrowIn,
            fontFamily: BRAND.body,
            fontStyle: 'italic',
            fontSize: 32,
            color: BRAND.rouge,
          }}
        >
          relecture par ton ↓
        </div>

        {/* Carte Mail (formel) */}
        <div
          style={{
            position: 'absolute',
            top: 840,
            left: 90,
            right: 90,
            transform: `translateY(${interpolate(mailIn, [0, 1], [44, 0])}px)`,
            opacity: mailOpacity,
            background: '#fbf5e8',
            border: `2px solid ${BRAND.rouge}`,
            borderRadius: 26,
            padding: '34px 40px 40px',
            boxShadow: '0 26px 60px rgba(140,43,33,0.18)',
          }}
        >
          <div style={{marginBottom: 22}}>
            <Tag label="Mail" tone="formal" />
          </div>
          <div style={{fontFamily: BRAND.body, fontSize: 46, lineHeight: 1.45, color: BRAND.ink, minHeight: 130, opacity: formalIn, filter: `blur(${formalBlur}px)`}}>
            {FORMAL}
          </div>
        </div>

        <Caption inAt={250} outAt={330} bottom={250}>Même fond.</Caption>
        <Caption inAt={336} outAt={410} bottom={250}>Le registre s'adapte à l'app.</Caption>
      </AbsoluteFill>

      <EndCard
        inAt={420}
        title={<>Le bon ton,<br />soufflé à voix basse.</>}
        tagline="reformulé en français, sur ta machine"
      />
    </AbsoluteFill>
  );
};
