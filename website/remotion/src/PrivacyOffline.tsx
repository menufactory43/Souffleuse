import {
  AbsoluteFill,
  interpolate,
  interpolateColors,
  spring,
  useCurrentFrame,
  useVideoConfig,
} from 'remotion';
import {BRAND} from './brand';
import {useBrandFonts} from './useBrandFonts';
import {band, Caption, EndCard, Keycap, Score, Vignette, Wordmark} from './components';

const TYPED = 'Désolé du retard, je vous envoie le doc';
const GHOST = ' corrigé d’ici ce soir.';

const Wifi: React.FC<{on: number}> = ({on}) => (
  <svg width="44" height="36" viewBox="0 0 24 20" style={{opacity: 0.3 + 0.7 * on}}>
    <path d="M12 17.5l2.5-3a3.2 3.2 0 0 0-5 0z" fill={BRAND.ink} />
    <path d="M6.5 10.5a8 8 0 0 1 11 0" stroke={BRAND.ink} strokeWidth="2" fill="none" strokeLinecap="round" />
    <path d="M3.5 7a12 12 0 0 1 17 0" stroke={BRAND.ink} strokeWidth="2" fill="none" strokeLinecap="round" />
    {on < 0.5 ? (
      <line x1="3" y1="3" x2="21" y2="18" stroke={BRAND.rouge} strokeWidth="2" strokeLinecap="round" />
    ) : null}
  </svg>
);

export const PrivacyOffline: React.FC = () => {
  useBrandFonts();
  const frame = useCurrentFrame();
  const {fps} = useVideoConfig();

  const intro = interpolate(frame, [0, 18], [0, 1], {extrapolateRight: 'clamp'});
  const cardIn = spring({frame: frame - 110, fps, config: {damping: 200}});
  const cardOpacity = interpolate(frame, [108, 128], [0, 1], {extrapolateLeft: 'clamp', extrapolateRight: 'clamp'});

  // Coupure Wi-Fi vers la frame 75.
  const wifiOn = interpolate(frame, [72, 86], [1, 0], {extrapolateLeft: 'clamp', extrapolateRight: 'clamp'});
  const planeIn = band(frame, 88, 540, 10);

  // Frappe puis souffle.
  const typedCount = Math.max(0, Math.min(TYPED.length, Math.floor(interpolate(frame, [132, 250], [0, TYPED.length]))));
  const typedVisible = TYPED.slice(0, typedCount);
  const typingDone = typedCount >= TYPED.length;
  const ghostOpacity = interpolate(frame, [258, 284], [0, 1], {extrapolateLeft: 'clamp', extrapolateRight: 'clamp'});
  const ghostBlur = interpolate(frame, [258, 284], [7, 0], {extrapolateLeft: 'clamp', extrapolateRight: 'clamp'});
  const breathe = frame > 284 && frame < 352 ? 0.86 + 0.14 * (0.5 + 0.5 * Math.sin((frame - 284) / 7)) : 1;
  const ghostColor = interpolateColors(frame, [356, 374], [BRAND.ghost, BRAND.ink]);
  const accepted = frame >= 368;

  const tabIn = interpolate(frame, [320, 338], [0, 1], {extrapolateLeft: 'clamp', extrapolateRight: 'clamp'});
  const press = spring({frame: frame - 352, fps, config: {damping: 12, mass: 0.4}});
  const tabScale = 1 - 0.12 * press * (frame < 366 ? 1 : interpolate(frame, [366, 382], [1, 0], {extrapolateRight: 'clamp'}));
  const tabGlow = band(frame, 350, 386, 8);
  const sweep = band(frame, 358, 382, 6);

  const caretBlink = frame % 30 < 15 ? 1 : 0;
  const caretFade = interpolate(frame, [364, 376], [1, 0], {extrapolateLeft: 'clamp', extrapolateRight: 'clamp'});
  const caretOpacity = (frame < 284 ? (typingDone ? caretBlink : 1) : caretBlink) * caretFade;

  const stageOut = interpolate(frame, [486, 506], [1, 0], {extrapolateLeft: 'clamp', extrapolateRight: 'clamp'});

  return (
    <AbsoluteFill style={{backgroundColor: BRAND.paper, overflow: 'hidden'}}>
      <Score src="audio/score-gnossienne1.mp3" />
      <Vignette />

      <AbsoluteFill style={{opacity: stageOut}}>
        {/* Barre de menus macOS stylisée */}
        <div
          style={{
            position: 'absolute',
            top: 0,
            left: 0,
            right: 0,
            height: 70,
            background: 'rgba(26,22,19,0.05)',
            borderBottom: `1px solid ${BRAND.paperDark}`,
            display: 'flex',
            alignItems: 'center',
            justifyContent: 'flex-end',
            gap: 26,
            padding: '0 44px',
            opacity: intro,
          }}
        >
          {planeIn > 0.05 ? (
            <span
              style={{
                fontFamily: BRAND.body,
                fontSize: 28,
                color: BRAND.rouge,
                opacity: planeIn,
                border: `2px solid ${BRAND.rouge}`,
                borderRadius: 12,
                padding: '4px 16px',
              }}
            >
              ✈ Avion
            </span>
          ) : null}
          <Wifi on={wifiOn} />
          <span style={{fontFamily: BRAND.body, fontSize: 30, color: BRAND.ink}}>21:47</span>
        </div>

        <Wordmark opacity={intro} subtitle="— ce qui se dit en coulisse reste en coulisse." />

        {/* Carte */}
        <div
          style={{
            position: 'absolute',
            top: 560,
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
            <span>À : Léa</span>
            <span style={{fontStyle: 'italic'}}>Hors ligne</span>
          </div>
          <div style={{fontFamily: BRAND.body, fontWeight: 400, fontSize: 50, lineHeight: 1.5, color: BRAND.ink, minHeight: 230}}>
            <span style={{position: 'relative'}}>
              <span style={{position: 'absolute', left: -6, right: -6, top: 4, bottom: 4, background: BRAND.rouge, opacity: sweep * 0.12, borderRadius: 8}} />
              {typedVisible}
              <span style={{color: ghostColor, opacity: ghostOpacity * (accepted ? 1 : breathe), filter: `blur(${ghostBlur}px)`}}>
                {ghostOpacity > 0 ? GHOST : ''}
              </span>
              <span style={{display: 'inline-block', width: 4, height: 50, marginLeft: 3, transform: 'translateY(10px)', background: BRAND.ink, opacity: caretOpacity}} />
            </span>
          </div>
        </div>

        {/* Touche Tab */}
        <div style={{position: 'absolute', left: 0, right: 0, bottom: 470, display: 'flex', justifyContent: 'center', alignItems: 'center', gap: 22, opacity: tabIn}}>
          <Keycap label="⇥ Tab" scale={tabScale} glow={tabGlow} />
          <span style={{fontFamily: BRAND.body, fontStyle: 'italic', fontSize: 34, color: BRAND.ghost}}>même sans réseau</span>
        </div>

        <Caption inAt={92} outAt={170}>Wi-Fi coupé. Mode avion.</Caption>
        <Caption inAt={288} outAt={352}>Et elle souffle quand même.</Caption>
        <Caption inAt={392} outAt={462}>Aucun texte n'a quitté le Mac.</Caption>
      </AbsoluteFill>

      <EndCard
        inAt={490}
        title={<>100&nbsp;% local.<br />Par construction.</>}
        tagline="le modèle tourne sur ton Mac · rien ne sort, jamais"
      />
    </AbsoluteFill>
  );
};
