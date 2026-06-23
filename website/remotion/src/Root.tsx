import {Composition} from 'remotion';
import {MagicMoment} from './MagicMoment';
import {PrivacyOffline} from './PrivacyOffline';
import {Translation} from './Translation';
import {ToneShift} from './ToneShift';

// Une composition par Short. Format Shorts : 1080×1920, 30 fps.
// Chaque Short a sa propre musique (voir CREDITS.md).
export const RemotionRoot: React.FC = () => {
  return (
    <>
      {/* ① Le « magic moment » — Gymnopédie No.1 (K. MacLeod, CC BY) */}
      <Composition id="MagicMoment" component={MagicMoment} durationInFrames={450} fps={30} width={1080} height={1920} />
      {/* ② Privacy / Wi-Fi coupé — Satie Gnossienne No.1 (CC BY) */}
      <Composition id="PrivacyOffline" component={PrivacyOffline} durationInFrames={540} fps={30} width={1080} height={1920} />
      {/* ③ Traduction — Debussy 1ère Arabesque (domaine public) */}
      <Composition id="Translation" component={Translation} durationInFrames={480} fps={30} width={1080} height={1920} />
      {/* ④ Relecture par ton — Satie Gnossienne No.3 (CC BY) */}
      <Composition id="ToneShift" component={ToneShift} durationInFrames={480} fps={30} width={1080} height={1920} />
    </>
  );
};
