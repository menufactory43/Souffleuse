import React from 'react';
import {
  AbsoluteFill,
  Audio,
  interpolate,
  staticFile,
  useCurrentFrame,
  useVideoConfig,
} from 'remotion';
import {BRAND} from './brand';

// Enveloppe fondu entrée/sortie.
export const band = (frame: number, inAt: number, outAt: number, dur = 12) =>
  interpolate(frame, [inAt, inAt + dur, outAt - dur, outAt], [0, 1, 1, 0], {
    extrapolateLeft: 'clamp',
    extrapolateRight: 'clamp',
  });

export const Vignette: React.FC = () => (
  <AbsoluteFill
    style={{
      background:
        'radial-gradient(120% 80% at 50% 38%, rgba(0,0,0,0) 55%, rgba(26,22,19,0.10) 100%)',
    }}
  />
);

// Musique en sourdine, fondu d'entrée/sortie calé sur la durée de la composition.
export const Score: React.FC<{src: string; volume?: number}> = ({src, volume = 0.4}) => {
  const {durationInFrames} = useVideoConfig();
  return (
    <Audio
      src={staticFile(src)}
      volume={(f) =>
        interpolate(
          f,
          [0, 18, durationInFrames - 40, durationInFrames],
          [0, volume, volume, 0],
          {extrapolateLeft: 'clamp', extrapolateRight: 'clamp'},
        )
      }
    />
  );
};

export const Wordmark: React.FC<{opacity?: number; subtitle?: string}> = ({
  opacity = 1,
  subtitle,
}) => (
  <>
    <div
      style={{
        position: 'absolute',
        top: 120,
        left: 0,
        right: 0,
        textAlign: 'center',
        opacity,
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
    {subtitle ? (
      <div
        style={{
          position: 'absolute',
          top: 182,
          left: 0,
          right: 0,
          textAlign: 'center',
          opacity: opacity * 0.7,
          fontFamily: BRAND.body,
          fontStyle: 'italic',
          fontSize: 28,
          color: BRAND.ghost,
        }}
      >
        {subtitle}
      </div>
    ) : null}
  </>
);

export const Caption: React.FC<{
  inAt: number;
  outAt: number;
  bottom?: number;
  children: React.ReactNode;
}> = ({inAt, outAt, bottom = 340, children}) => {
  const frame = useCurrentFrame();
  const o = band(frame, inAt, outAt);
  const y = interpolate(o, [0, 1], [14, 0]);
  return (
    <div
      style={{
        position: 'absolute',
        left: 0,
        right: 0,
        bottom,
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

export const Keycap: React.FC<{label: string; scale?: number; glow?: number}> = ({
  label,
  scale = 1,
  glow = 0,
}) => (
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
      transform: `scale(${scale})`,
      boxShadow: `0 0 ${30 * glow}px rgba(140,43,33,${0.55 * glow})`,
    }}
  >
    {label}
  </div>
);

export const EndCard: React.FC<{
  inAt: number;
  title: React.ReactNode;
  tagline?: string;
}> = ({inAt, title, tagline = '100 % local · gratuit pendant la bêta'}) => {
  const frame = useCurrentFrame();
  const {durationInFrames} = useVideoConfig();
  const o = band(frame, inAt, durationInFrames + 30, 16);
  return (
    <AbsoluteFill
      style={{
        opacity: o,
        justifyContent: 'center',
        alignItems: 'center',
        padding: '0 110px',
        textAlign: 'center',
      }}
    >
      <div style={{fontFamily: BRAND.display, fontWeight: 900, fontSize: 84, lineHeight: 1.12, color: BRAND.ink}}>
        {title}
      </div>
      <div style={{width: 120, height: 4, background: BRAND.rouge, margin: '46px auto 40px'}} />
      <div style={{fontFamily: BRAND.body, fontWeight: 500, fontSize: 50, letterSpacing: 1, color: BRAND.rouge}}>
        souffleuse.app
      </div>
      <div style={{marginTop: 26, fontFamily: BRAND.body, fontStyle: 'italic', fontSize: 32, color: BRAND.ghost}}>
        {tagline}
      </div>
    </AbsoluteFill>
  );
};
