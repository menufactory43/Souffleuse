import {AbsoluteFill} from 'remotion';
import {C} from './theme';

/** Grain papier — même recette que le site : deux trames de points multipliées. */
export const Grain = () => {
    return (
        <AbsoluteFill
            style={{
                pointerEvents: 'none',
                opacity: 0.45,
                mixBlendMode: 'multiply',
                backgroundImage:
                    'radial-gradient(rgba(60,45,25,0.06) 1px, transparent 1px),' +
                    'radial-gradient(rgba(60,45,25,0.04) 1px, transparent 1px)',
                backgroundSize: '3px 3px, 5px 5px',
                backgroundPosition: '0 0, 2px 2px',
            }}
        />
    );
};

export const PaperFill = ({children}: {children: React.ReactNode}) => {
    return (
        <AbsoluteFill style={{backgroundColor: C.paper}}>
            {children}
        </AbsoluteFill>
    );
};
