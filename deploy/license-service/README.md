# Service licences — Bitcoin/Lightning (VPS)

Caisse d'activation de licence Souffleuse en **Lightning** (paiement) → **jeton
Ed25519 auto-signé** (format `LicenseKey`, vérifié hors-ligne par l'app). Vit sur le
VPS `170.75.168.21` (Debian 12). Cohabite avec la page de **dons** LNURL existante.

## Architecture (sur le VPS)

```
pay.souffleuse.app  ──►  Caddy (TLS auto)
                          ├─ /buy*  ──►  127.0.0.1:8089  licensed.py   (licences)
                          └─ reste  ──►  127.0.0.1:8088  lnurld.py     (dons LNURL)
licensed / lnurld   ──►  phoenixd 127.0.0.1:9740  (Lightning, user `phoenix`)
```

- **`licensed.py`** : `GET /buy` (page), `POST /buy/create` {email} → facture
  Lightning à prix fixe **39 € → sats** (taux **mempool.space**, repli CoinGecko)
  expirant en **15 min** ; `GET /buy/status?h=` → à paiement (re-vérifié via l'API
  phoenixd) **signe le jeton `SOUF-…`** lié à l'email et l'affiche. Page = countdown
  + « Régénérer ». Livraison = page de succès (pas d'e-mail).
- **`licensed.service`** : unit systemd (user `phoenix`).
- **`Caddyfile`** : routage `/buy*` → licences, reste → dons.

## Fichiers sur le VPS (NON versionnés)

- `/opt/licensed/licensed.py` (= ce dossier), `/opt/licensed/licenses.db` (SQLite),
  `/opt/licensed/signing_key.b64` (**clé PRIVÉE Ed25519, 600, à SAUVEGARDER hors-ligne**).
- `/home/phoenix/.phoenix/` (**seed phoenixd, à SAUVEGARDER hors-ligne**).

La **clé PUBLIQUE** correspondante est embarquée dans l'app
(`LicenseGate.publicKeyBase64`). Vérifié bout-en-bout : un jeton signé par le VPS
est `VALID` dans le code de vérif de l'app.

## Déployer / mettre à jour

⚠️ Le hook `rtk` filtre le contenu des pipes → transférer en **base64** et vérifier
le **SHA-256**, sinon le fichier arrive corrompu :

```sh
rtk proxy sh -c '
  F=deploy/license-service/licensed.py
  base64 < "$F" | ssh -i ~/.ssh/id_ed25519 debian@170.75.168.21 \
    "base64 -d | sudo tee /opt/licensed/licensed.py >/dev/null && sudo chown phoenix:phoenix /opt/licensed/licensed.py"
'
ssh ... "sudo systemctl restart licensed"
```

(SSH : user `debian`, clé `~/.ssh/id_ed25519`, sudo NOPASSWD.)

## Avant d'encaisser réellement

1. **Sauvegarder hors-ligne** le seed phoenixd ET `signing_key.b64`.
2. **Shipper un build de l'app** contenant la clé publique de prod (les anciens
   builds ont l'ancienne clé → leurs jetons ne vérifieront pas).
3. **Activer le paywall** (`LicenseGate.paywallEnabled = true`) puis rebuild.
4. **Fiscal** : en BTC direct, pas de Merchant of Record → TVA/déclaration à ta charge.
