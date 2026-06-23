import {useCallback, useEffect, useState} from 'react';
import {continueRender, delayRender, staticFile} from 'remotion';

// Charge les woff2 de la marque (copiés dans public/fonts) avant le rendu, pour
// qu'aucune frame ne soit capturée avec une police de fallback.
export const useBrandFonts = () => {
  const [handle] = useState(() => delayRender('chargement-fonts'));

  const load = useCallback(async () => {
    const faces = [
      new FontFace('Bodoni Moda', `url(${staticFile('fonts/bodoni-moda-700-normal-latin.woff2')}) format('woff2')`, {weight: '700'}),
      new FontFace('Bodoni Moda', `url(${staticFile('fonts/bodoni-moda-900-normal-latin.woff2')}) format('woff2')`, {weight: '900'}),
      new FontFace('Spectral', `url(${staticFile('fonts/spectral-400-normal-latin.woff2')}) format('woff2')`, {weight: '400'}),
      new FontFace('Spectral', `url(${staticFile('fonts/spectral-500-normal-latin.woff2')}) format('woff2')`, {weight: '500'}),
      new FontFace('Spectral', `url(${staticFile('fonts/spectral-400-italic-latin.woff2')}) format('woff2')`, {weight: '400', style: 'italic'}),
    ];
    await Promise.all(faces.map((f) => f.load()));
    faces.forEach((f) => document.fonts.add(f));
    await document.fonts.ready;
    continueRender(handle);
  }, [handle]);

  useEffect(() => {
    load();
  }, [load]);
};
