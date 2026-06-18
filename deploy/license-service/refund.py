#!/usr/bin/env python3
# Outil de remboursement Lightning — garantie 14 jours (manuel).
#
# Lightning ne porte AUCUNE adresse de retour : on ne peut pas rembourser
# l'expediteur automatiquement. Le client fournit SA facture (bolt11) par e-mail,
# et on la paie. Ce script securise l'operation :
#   refund <email>            -> LECTURE SEULE : commandes du client + fenetre 14j
#                                + balance phoenixd. Aucun argent ne bouge.
#   refund <email> <bolt11>   -> PAIE la facture fournie (apres confirmation
#                                interactive). Utilise le mot de passe phoenixd
#                                *full* (le limited-access ne peut pas envoyer).
#
# A lancer en user `phoenix` sur le VPS (acces conf + cles). Reutilise licensed.py
# pour la DB (_db), l'API phoenixd (API) et la fenetre commune.
import sys, time, datetime, json, base64, urllib.request, urllib.parse
sys.path.insert(0, "/opt/licensed")
import licensed

REFUND_WINDOW_DAYS = 14

def _full_pw() -> str:
    # Mot de passe phoenixd COMPLET (droit d'envoi). Distinct du limited-access
    # de licensed.py : "http-password=" ne matche pas "http-password-limited-access=".
    for line in open(licensed.CONF):
        if line.startswith("http-password="):
            return line.strip().split("=", 1)[1]
    raise RuntimeError("no http-password (full) in conf")

def phx_full(path: str, data=None):
    body = urllib.parse.urlencode(data).encode() if data else None
    req = urllib.request.Request(licensed.API + path, data=body)
    req.add_header("Authorization", "Basic " + base64.b64encode((":" + _full_pw()).encode()).decode())
    with urllib.request.urlopen(req, timeout=40) as r:
        return json.load(r)

def orders_for(email: str):
    c = licensed._db()
    rows = c.execute(
        "SELECT hash, email, sats, token, created FROM orders "
        "WHERE lower(email)=lower(?) ORDER BY created DESC",
        (email.strip(),),
    ).fetchall()
    c.close()
    return rows

def balance():
    try:
        b = licensed.phx("/getbalance")          # lecture -> limited-access suffit
        return int(b.get("balanceSat", 0)), int(b.get("feeCreditSat", 0))
    except Exception:
        return None, None

def fmt_ts(ts) -> str:
    return datetime.datetime.utcfromtimestamp(int(ts)).strftime("%Y-%m-%d %H:%M UTC")

def main():
    if len(sys.argv) < 2:
        print("usage: refund <email> [bolt11]"); sys.exit(2)
    email = sys.argv[1]
    bolt11 = sys.argv[2].strip() if len(sys.argv) > 2 else None

    rows = orders_for(email)
    if not rows:
        print(f"Aucune commande pour {email!r}."); sys.exit(1)

    now = int(time.time())
    print(f"Commandes pour {email} :\n")
    chosen = None  # (hash, sats) : 1re commande payee ET dans la fenetre
    for h, em, sats, token, created in rows:
        age = (now - int(created)) / 86400
        in_window = age <= REFUND_WINDOW_DAYS
        paid = "payee" if token else "NON payee"
        flag = "OK 14j" if in_window else f"HORS fenetre ({age:.0f}j)"
        print(f"  {h[:16]}…  {sats} sats  {fmt_ts(created)}  ({age:.1f}j, {flag})  {paid}")
        if chosen is None and token and in_window:
            chosen = (h, int(sats))
    print()

    bal, credit = balance()
    if bal is not None:
        print(f"phoenixd : balanceSat={bal}  feeCreditSat={credit}")

    if chosen is None:
        print("\n→ Aucune commande payee ET dans la fenetre 14j. Remboursement non recommande.")
        sys.exit(0)
    h, sats = chosen

    if bal is not None and bal < sats:
        print(f"\n⚠ Balance insuffisante ({bal} < {sats} sats) : phoenixd ne peut pas envoyer.")
        print("  Finance le noeud / attends l'ouverture d'un canal avant de rembourser.")

    if not bolt11:
        print(f"\nDemande au client une facture Lightning de {sats} sats, puis :")
        print(f"  refund {email} <bolt11_du_client>")
        sys.exit(0)

    # --- Paiement reel ---
    if bal is not None and bal < sats:
        print("\nRefus : balance insuffisante pour rembourser."); sys.exit(1)
    print(f"\nPaiement de la facture fournie (montant attendu ~{sats} sats).")
    if input("Confirmer le remboursement ? [oui/non] ").strip().lower() not in ("oui", "o", "yes", "y"):
        print("Annule."); sys.exit(0)
    try:
        res = phx_full("/payinvoice", {"invoice": bolt11})
    except Exception as e:
        print("Echec du paiement :", e); sys.exit(1)
    print("Resultat :", json.dumps(res))
    if res.get("paymentPreimage") or res.get("paymentId"):
        print("→ Remboursement envoye. Note : la cle de licence reste valable (pas de revocation).")

if __name__ == "__main__":
    main()
