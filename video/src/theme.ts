import {loadFont as loadBodoni} from '@remotion/google-fonts/BodoniModa';
import {loadFont as loadSpectral} from '@remotion/google-fonts/Spectral';

const bodoni = loadBodoni();
const spectral = loadSpectral();

/** Jeu de couleurs du Livret — repris tel quel de website/index.html. */
export const C = {
    paper: '#f3ead9',
    paperDeep: '#ece0c9',
    paperEdge: '#e3d5ba',
    paperCard: '#fbf5ea',
    ink: '#1a1613',
    inkSoft: '#463d33',
    inkFaint: '#5e5446',
    ghost: '#a99a82',
    rouge: '#8c2b21',
    rougeDeep: '#6f2018',
} as const;

export const DISPLAY = `${bodoni.fontFamily}, Georgia, serif`;
export const BODY = `${spectral.fontFamily}, Georgia, serif`;
