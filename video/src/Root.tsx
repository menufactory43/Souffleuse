import {Composition} from 'remotion';
import {Main, TOTAL_FRAMES} from './Main';
import {Rafale, RAFALE_FRAMES} from './scenes/Rafale';
import {Cafe, CAFE_FRAMES} from './scenes/Cafe';
import {CafeVertical} from './scenes/CafeVertical';
import {DefiTab, DEFITAB_FRAMES} from './scenes/DefiTab';
import {Screencast, SCREENCAST_FRAMES, SCREENCAST_SQUARE_FRAMES} from './scenes/Screencast';

/**
 * Racine Remotion : trois compositions.
 * Souffleuse       — 16:9, 1920×1080, la démo longue en trois actes.
 * SouffleuseRafale — 9:16, 1080×1920, la rafale courte pour les réseaux sociaux.
 * SouffleuseCafe   — 16:9, 1920×1080, le numéro comparatif (vs la dictée vocale).
 *
 * Les compositions sont indépendantes : ni leurs bandes-son ni leurs fichiers
 * sources ne se partagent.
 */
export const RemotionRoot = () => {
    return (
        <>
            <Composition
                id="Souffleuse"
                component={Main}
                durationInFrames={TOTAL_FRAMES}
                fps={30}
                width={1920}
                height={1080}
            />
            <Composition
                id="SouffleuseRafale"
                component={Rafale}
                durationInFrames={RAFALE_FRAMES}
                fps={30}
                width={1080}
                height={1920}
            />
            <Composition
                id="SouffleuseCafe"
                component={Cafe}
                durationInFrames={CAFE_FRAMES}
                fps={30}
                width={1920}
                height={1080}
            />
            <Composition
                id="SouffleuseCafeVertical"
                component={CafeVertical}
                durationInFrames={CAFE_FRAMES}
                fps={30}
                width={1080}
                height={1920}
            />
            <Composition
                id="DefiTabVertical"
                component={DefiTab}
                durationInFrames={DEFITAB_FRAMES}
                fps={30}
                width={1080}
                height={1920}
            />
            <Composition
                id="DefiTab16x9"
                component={DefiTab}
                durationInFrames={DEFITAB_FRAMES}
                fps={30}
                width={1920}
                height={1080}
            />
            <Composition
                id="ScreencastVertical"
                component={Screencast}
                durationInFrames={SCREENCAST_FRAMES}
                fps={30}
                width={1080}
                height={1920}
            />
            <Composition
                id="Screencast16x9"
                component={Screencast}
                durationInFrames={SCREENCAST_FRAMES}
                fps={30}
                width={1920}
                height={1080}
            />
            <Composition
                id="ScreencastSquare"
                component={Screencast}
                durationInFrames={SCREENCAST_SQUARE_FRAMES}
                fps={30}
                width={1080}
                height={1350}
            />
        </>
    );
};
