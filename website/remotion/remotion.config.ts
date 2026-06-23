import {Config} from '@remotion/cli/config';

// Sortie verticale propre pour les Shorts ; on écrase l'ancien rendu à chaque run.
Config.setVideoImageFormat('jpeg');
Config.setOverwriteOutput(true);
Config.setConcurrency(4);
