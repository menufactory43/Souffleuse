import {AbsoluteFill, Audio, Sequence, staticFile} from 'remotion';
import {Grain} from './Paper';
import {C, BODY} from './theme';
import {TroisCoups} from './scenes/TroisCoups';
import {Affiche} from './scenes/Affiche';
import {ActeSouffle} from './scenes/ActeSouffle';
import {ActeMidLine} from './scenes/ActeMidLine';
import {ActeRelecture} from './scenes/ActeRelecture';
import {Coulisses} from './scenes/Coulisses';
import {Finale} from './scenes/Finale';

// Découpage en trois actes : ouverture, affiche, le souffle, le plein milieu,
// la relecture, coulisses, salut. 30 fps. La bande-son (make-bande-son.mjs)
// est calée sur ces bornes — recaler les deux ensemble.
const T = {
    coups: {from: 0, dur: 115},
    affiche: {from: 108, dur: 192},
    acte1: {from: 295, dur: 270},
    acte2: {from: 558, dur: 300},
    acte3: {from: 850, dur: 330},
    coulisses: {from: 1172, dur: 185},
    finale: {from: 1349, dur: 245},
} as const;

export const TOTAL_FRAMES = T.finale.from + T.finale.dur; // 1594 ≈ 53,1 s

export const Main = () => {
    return (
        <AbsoluteFill style={{backgroundColor: C.paper, fontFamily: BODY}}>
            {/* Chopin, valse op. 64 n° 2 (domaine public) + les trois coups du
                brigadier — mixés par scripts/make-bande-son.mjs (preset valse) */}
            <Audio src={staticFile('bande-son.wav')} />
            <Sequence from={T.coups.from} durationInFrames={T.coups.dur}>
                <TroisCoups duration={T.coups.dur} />
            </Sequence>
            <Sequence from={T.affiche.from} durationInFrames={T.affiche.dur}>
                <Affiche duration={T.affiche.dur} />
            </Sequence>
            <Sequence from={T.acte1.from} durationInFrames={T.acte1.dur}>
                <ActeSouffle duration={T.acte1.dur} />
            </Sequence>
            <Sequence from={T.acte2.from} durationInFrames={T.acte2.dur}>
                <ActeMidLine duration={T.acte2.dur} />
            </Sequence>
            <Sequence from={T.acte3.from} durationInFrames={T.acte3.dur}>
                <ActeRelecture duration={T.acte3.dur} />
            </Sequence>
            <Sequence from={T.coulisses.from} durationInFrames={T.coulisses.dur}>
                <Coulisses duration={T.coulisses.dur} />
            </Sequence>
            <Sequence from={T.finale.from} durationInFrames={T.finale.dur}>
                <Finale duration={T.finale.dur} />
            </Sequence>
            {/* Le grain papier couvre tout, rideau compris */}
            <Grain />
        </AbsoluteFill>
    );
};
