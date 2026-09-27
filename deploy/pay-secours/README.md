# pay-secours — dépannage de pay.souffleuse.app

Posé le 27/09/2026 pendant la panne du VPS 170.75.168.21 (licensed.py + dons LNURL injoignables, erreur 523 depuis l'extérieur).
Le bouton « Acheter » de l'app ouvre https://pay.souffleuse.app/buy/studio : ici, /buy et /buy/* renvoient (302) directement
vers le checkout carte Lemon Squeezy (LEMON_URL de licensed.py). Tout le reste renvoie vers souffleuse.app.
Pendant le dépannage : carte seulement, pas de Lightning, pas de page de dons.

## Revenir au VPS (quand il répond de nouveau)

    vercel domains rm pay.souffleuse.app --yes          # retire le domaine du projet souffleuse-pay-secours
    vercel dns add souffleuse.app pay A 170.75.168.21   # l'enregistrement d'origine (rec_1ee8c60e37b521d798fa3986)

Puis vérifier https://pay.souffleuse.app/buy/studio (page de choix carte / Lightning servie par Caddy).
