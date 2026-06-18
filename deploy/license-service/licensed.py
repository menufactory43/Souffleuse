#!/usr/bin/env python3
# Service licences Souffleuse : facture Lightning a prix fixe (EUR), et a paiement
# confirme (re-verifie via l'API phoenixd, jamais un webhook seul) signe un jeton
# Ed25519 au format LicenseKey, lie a l'email. Livraison = page de succes.
# Taux : mempool.space (bitcoiner, non-CEX) -> repli CoinGecko. Facture a la volee,
# montant en sats au cours du moment, expiration courte (15 min) + regeneration.
import json, base64, sqlite3, subprocess, urllib.request, urllib.parse, re, time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey

CONF = "/home/phoenix/.phoenix/phoenix.conf"
API = "http://127.0.0.1:9740"
PRICE_EUR = 39.0
EXPIRY_S = 900                     # 15 min : borne la derive de change sur la facture
DB = "/opt/licensed/licenses.db"
KEYFILE = "/opt/licensed/signing_key.b64"
LISTEN = ("127.0.0.1", 8089)
EMAIL_RE = re.compile(r"^[^@\s]+@[^@\s]+\.[^@\s]+$")

# --- Signature au format LicenseKey : SOUF-<b64url(email_canon)>.<b64url(sig)> ---
def b64url(b: bytes) -> str:
    return base64.urlsafe_b64encode(b).decode().rstrip("=")

PRIV = Ed25519PrivateKey.from_private_bytes(base64.b64decode(open(KEYFILE).read().strip()))

def sign_license(email: str) -> str:
    canon = email.strip().lower().encode()           # meme canonicalisation que LicenseKey.canonical
    return "SOUF-" + b64url(canon) + "." + b64url(PRIV.sign(canon))

# --- Client phoenixd (mot de passe a acces LIMITE : creer/lire, pas depenser) ---
def _limited_pw() -> str:
    for line in open(CONF):
        if line.startswith("http-password-limited-access="):
            return line.strip().split("=", 1)[1]
    raise RuntimeError("no limited pw in conf")

AUTH = "Basic " + base64.b64encode((":" + _limited_pw()).encode()).decode()

def phx(path: str, data=None):
    body = urllib.parse.urlencode(data).encode() if data else None
    req = urllib.request.Request(API + path, data=body)
    req.add_header("Authorization", AUTH)
    with urllib.request.urlopen(req, timeout=30) as r:
        return json.load(r)

# --- Taux EUR -> sats : mempool.space d'abord (bitcoiner), CoinGecko en repli ---
def _rate_mempool() -> float:
    with urllib.request.urlopen("https://mempool.space/api/v1/prices", timeout=12) as r:
        return float(json.load(r)["EUR"])

def _rate_coingecko() -> float:
    url = "https://api.coingecko.com/api/v3/simple/price?ids=bitcoin&vs_currencies=eur"
    with urllib.request.urlopen(url, timeout=12) as r:
        return float(json.load(r)["bitcoin"]["eur"])

def eur_to_sat(eur: float) -> int:
    for src in (_rate_mempool, _rate_coingecko):
        try:
            btceur = src()
            if btceur > 0:
                return max(1, round(eur / btceur * 1e8))
        except Exception:
            continue
    raise RuntimeError("no rate source available")

# --- Persistance (idempotence : un hash -> un email -> un jeton) ---
def _db():
    c = sqlite3.connect(DB)
    c.execute("""CREATE TABLE IF NOT EXISTS orders(
        hash TEXT PRIMARY KEY, email TEXT, sats INTEGER, token TEXT, created INTEGER)""")
    if "lang" not in [r[1] for r in c.execute("PRAGMA table_info(orders)").fetchall()]:
        c.execute("ALTER TABLE orders ADD COLUMN lang TEXT DEFAULT 'fr'")   # migration
    c.commit()
    return c

def order_create(h, email, sats, lang):
    c = _db(); c.execute("INSERT OR REPLACE INTO orders(hash,email,sats,token,created,lang) VALUES(?,?,?,NULL,?,?)",
                         (h, email, sats, int(time.time()), lang)); c.commit(); c.close()

def order_get(h):
    c = _db(); row = c.execute("SELECT email,sats,token,lang FROM orders WHERE hash=?", (h,)).fetchone(); c.close()
    return row

def detect_lang(accept_language: str) -> str:
    # Signal le plus fiable : Accept-Language du navigateur au checkout. FR-first
    # par defaut (marque), EN pour toute langue explicitement non francaise.
    al = (accept_language or "").strip().lower()
    if not al:
        return "fr"
    return "fr" if al.split(",")[0].strip().startswith("fr") else "en"

def order_set_token(h, token):
    c = _db(); c.execute("UPDATE orders SET token=? WHERE hash=?", (token, h)); c.commit(); c.close()

# --- E-mail du recu (Resend, HTTPS) ---
# Cle d'envoi (scope "sending only") lue depuis /opt/licensed/resend.key (600).
# Aucun compte perso implique ; From = domaine verifie. Best-effort : si pas de
# cle ou echec, la page de succes affiche la cle quand meme.
RESEND_FROM = "Souffleuse <contact@souffleuse.app>"

# Chaines localisees du recu (FR / EN). Detection via Accept-Language au checkout.
EMAIL_STR = {
    "fr": {
        "subject": "Votre licence Souffleuse",
        "tagline": "Le mot juste, soufflé au creux du curseur.",
        "hi": "Merci pour votre achat !",
        "intro": "Voici votre clé de licence Souffleuse :",
        "steps": "Activation",
        "s1": "Ouvrez Souffleuse (barre de menus, en haut à droite)",
        "s2": "Réglages → Studio",
        "s3": "Collez la clé ci-dessus",
        "keep": "Conservez cet e-mail : la clé est rattachée à votre adresse.",
        "foot": "100% sur votre Mac",
    },
    "en": {
        "subject": "Your Souffleuse licence",
        "tagline": "The right word, whispered at your caret.",
        "hi": "Thank you for your purchase!",
        "intro": "Here is your Souffleuse licence key:",
        "steps": "Activation",
        "s1": "Open Souffleuse (menu bar, top right)",
        "s2": "Settings → Studio",
        "s3": "Paste the key above",
        "keep": "Keep this email: the key is tied to your address.",
        "foot": "100% on your Mac",
    },
}

def _resend_key():
    try:
        k = open("/opt/licensed/resend.key").read().strip()
        return k or None
    except FileNotFoundError:
        return None

def _email_html(token: str, s: dict) -> str:
    # HTML email-safe : tables + styles inline, police web-safe (Georgia/serif),
    # accent sang-de-boeuf #8c2b21. Rendu fiable Gmail/Apple Mail.
    return (
        '<table width="100%" cellpadding="0" cellspacing="0" role="presentation" '
        'style="background:#f3efe7;padding:28px 12px;font-family:Georgia,serif;">'
        '<tr><td align="center">'
        '<table width="480" cellpadding="0" cellspacing="0" role="presentation" '
        'style="max-width:480px;background:#fbf8f2;border:1px solid #e2d8c6;border-radius:14px;">'
        '<tr><td style="padding:32px;">'
        '<div style="font-size:26px;font-weight:bold;color:#8c2b21;letter-spacing:.01em;">Souffleuse</div>'
        f'<div style="font-style:italic;color:#6b6052;font-size:14px;margin-top:4px;">{s["tagline"]}</div>'
        f'<p style="color:#1a1613;font-size:15px;margin:24px 0 6px;">{s["hi"]}</p>'
        f'<p style="color:#1a1613;font-size:15px;margin:0 0 14px;">{s["intro"]}</p>'
        '<div style="font-family:Menlo,Consolas,monospace;font-size:13px;word-break:break-all;'
        f'background:#ffffff;border:2px solid #8c2b21;border-radius:8px;padding:14px;color:#1a1613;">{token}</div>'
        '<p style="color:#8c2b21;font-weight:bold;font-size:12px;text-transform:uppercase;'
        f'letter-spacing:.06em;margin:24px 0 8px;">{s["steps"]}</p>'
        '<ol style="color:#1a1613;font-size:14px;margin:0;padding-left:20px;">'
        f'<li style="margin:4px 0;">{s["s1"]}</li>'
        f'<li style="margin:4px 0;">{s["s2"]}</li>'
        f'<li style="margin:4px 0;">{s["s3"]}</li></ol>'
        f'<p style="color:#6b6052;font-size:13px;margin:22px 0 0;">{s["keep"]}</p>'
        '<hr style="border:none;border-top:1px solid #e2d8c6;margin:24px 0 12px;">'
        f'<div style="color:#8a7f70;font-size:12px;">souffleuse.app &middot; {s["foot"]}</div>'
        '</td></tr></table></td></tr></table>'
    )

def _email_text(token: str, s: dict) -> str:
    return (f'{s["hi"]}\n\n{s["intro"]}\n\n{token}\n\n'
            f'{s["steps"]} :\n1. {s["s1"]}\n2. {s["s2"]}\n3. {s["s3"]}\n\n'
            f'{s["keep"]}\n\n— Souffleuse\nhttps://souffleuse.app')

def send_license_email(to_email: str, token: str, lang: str = "fr") -> bool:
    key = _resend_key()
    if not key:
        return False
    s = EMAIL_STR.get(lang, EMAIL_STR["fr"])
    payload = json.dumps({
        "from": RESEND_FROM,
        "to": [to_email],
        "subject": s["subject"],
        "html": _email_html(token, s),
        "text": _email_text(token, s),
    }).encode()
    req = urllib.request.Request("https://api.resend.com/emails", data=payload, method="POST")
    req.add_header("Authorization", "Bearer " + key)
    req.add_header("Content-Type", "application/json")
    req.add_header("User-Agent", "souffleuse-licence/1.0")  # sinon Cloudflare bloque urllib (err 1010)
    try:
        with urllib.request.urlopen(req, timeout=20) as r:
            return r.status in (200, 201)
    except Exception:
        return False

# --- QR Lightning (server-side via qrencode -> SVG inline, zero appel externe) ---
def qr_svg(text: str) -> str:
    out = subprocess.run(["qrencode", "-t", "SVG", "-m", "1", "-o", "-", text],
                         capture_output=True, timeout=10)
    return out.stdout.decode() if out.returncode == 0 else ""

# --- Page de checkout ---
PAGE = """<!doctype html><html lang="fr"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>Souffleuse - licence</title><style>
:root{--ox:#8c2b21}
*{box-sizing:border-box}body{font-family:Georgia,'Times New Roman',serif;background:#f3efe7;color:#1a1613;
margin:0;min-height:100vh;display:flex;align-items:center;justify-content:center;padding:24px}
.card{background:#fbf8f2;border:1px solid #e2d8c6;border-radius:14px;max-width:420px;width:100%;
padding:32px;box-shadow:0 6px 30px rgba(140,43,33,.07)}
h1{font-size:24px;margin:0 0 4px}.sub{font-style:italic;color:#6b6052;margin:0 0 22px;font-size:14px}
label{display:block;font-size:13px;color:#6b6052;margin:0 0 6px}
input{width:100%;padding:11px 12px;border:1px solid #d8ccb8;border-radius:8px;font-size:15px;font-family:inherit;background:#fff}
button{width:100%;margin-top:16px;padding:12px;border:0;border-radius:8px;background:var(--ox);color:#fff;
font-family:inherit;font-size:15px;font-weight:600;cursor:pointer}button:disabled{opacity:.5;cursor:default}
.price{font-weight:700}.qr{text-align:center;margin:18px 0}.qr svg{width:220px;height:220px}
.inv{font-family:ui-monospace,monospace;font-size:11px;word-break:break-all;background:#f3efe7;
border:1px solid #e2d8c6;border-radius:8px;padding:10px;color:#5e5446}
.tok{font-family:ui-monospace,monospace;font-size:13px;word-break:break-all;background:#fff;
border:2px solid var(--ox);border-radius:8px;padding:14px;color:#1a1613;margin:10px 0}
.ok{color:var(--ox);font-weight:700;font-size:18px;text-align:center;margin:6px 0}
.muted{color:#6b6052;font-size:13px}.hide{display:none}a.ln{display:inline-block;margin-top:10px;color:var(--ox)}
small{color:#8a7f70}
</style></head><body><div class="card">
<div id="step1">
<h1>Souffleuse</h1><p class="sub">Licence complete - achat unique, paiement Lightning.</p>
<label for="email">Votre e-mail (votre licence y sera rattachee)</label>
<input id="email" type="email" placeholder="vous@exemple.fr" autocomplete="email">
<button id="buy">Acheter - <span class="price">39 &euro;</span></button>
<p class="muted" style="margin-top:14px">Paiement en bitcoin (Lightning). Le jeton de licence s'affiche des reception.</p>
</div>
<div id="step2" class="hide">
<h1>Payez <span class="price">39 &euro;</span></h1><p class="sub" id="amt"></p>
<div class="qr" id="qr"></div>
<a class="ln" id="lnlink" href="#">Ouvrir dans un portefeuille</a>
<details style="margin-top:10px"><summary class="muted">Copier la facture</summary>
<div class="inv" id="inv"></div></details>
<p class="muted" id="timer" style="margin-top:14px"></p>
<p class="muted" id="wait">En attente du paiement&hellip;</p>
<button id="regen" class="hide">Regenerer la facture</button>
</div>
<div id="step3" class="hide">
<div class="ok">&#10003; Merci !</div>
<p class="sub">Votre cle de licence. Copiez-la, puis collez-la dans Souffleuse (Reglages &rarr; Studio).</p>
<div class="tok" id="token"></div>
<button id="copy">Copier la cle</button>
<p class="muted" style="margin-top:12px">Cette cle est rattachee a votre e-mail. Gardez-la precieusement.</p>
</div>
<small style="display:block;margin-top:18px;text-align:center">souffleuse.app - 100% sur votre Mac</small>
</div>
<script>
const $=s=>document.querySelector(s);
let email=null, hash=null, pollT=null, cdT=null, left=0;
function tick(){
  if(left<=0){expired();return;}
  const m=Math.floor(left/60), s=String(left%60).padStart(2,"0");
  $("#timer").textContent="Expire dans "+m+":"+s; left--;
}
function expired(){clearInterval(cdT);clearInterval(pollT);
  $("#timer").textContent="Facture expiree.";$("#wait").textContent="";$("#regen").classList.remove("hide");}
async function createInvoice(){
  $("#regen").classList.add("hide");$("#wait").textContent="Creation de la facture...";
  const r=await fetch("/buy/create",{method:"POST",headers:{"Content-Type":"application/json"},body:JSON.stringify({email})});
  const d=await r.json(); if(d.error) throw new Error(d.error);
  hash=d.hash; $("#qr").innerHTML=d.qr; $("#inv").textContent=d.bolt11;
  $("#lnlink").href="lightning:"+d.bolt11; $("#amt").textContent=d.sats.toLocaleString("fr")+" sats";
  $("#wait").textContent="En attente du paiement\\u2026";
  left=d.expires_in||900; clearInterval(cdT); tick(); cdT=setInterval(tick,1000);
  clearInterval(pollT); pollT=setInterval(poll,2500); poll();
}
async function poll(){
  if(!hash)return;
  const d=await (await fetch("/buy/status?h="+hash)).json();
  if(d.paid&&d.token){clearInterval(pollT);clearInterval(cdT);
    $("#token").textContent=d.token;$("#step2").classList.add("hide");$("#step3").classList.remove("hide");}
  else if(d.expired){expired();}
}
$("#buy").onclick=async()=>{
  const e=$("#email").value.trim();
  if(!/^[^@\\s]+@[^@\\s]+\\.[^@\\s]+$/.test(e)){alert("E-mail invalide");return;}
  email=e;$("#buy").disabled=true;
  $("#step1").classList.add("hide");$("#step2").classList.remove("hide");
  try{await createInvoice();}
  catch(err){alert("Erreur: "+err.message);
    $("#step1").classList.remove("hide");$("#step2").classList.add("hide");
    $("#buy").disabled=false;$("#buy").textContent="Acheter - 39 \\u20ac";}
};
$("#regen").onclick=()=>createInvoice().catch(err=>alert("Erreur: "+err.message));
$("#copy").onclick=()=>{navigator.clipboard.writeText($("#token").textContent);$("#copy").textContent="Copie !";};
</script></body></html>"""

class H(BaseHTTPRequestHandler):
    def _json(self, obj, code=200):
        body = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers(); self.wfile.write(body)

    def _html(self, s):
        body = s.encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers(); self.wfile.write(body)

    def do_GET(self):
        u = urllib.parse.urlparse(self.path)
        if u.path in ("/buy", "/buy/"):
            self._html(PAGE)
        elif u.path == "/buy/status":
            h = urllib.parse.parse_qs(u.query).get("h", [""])[0]
            row = order_get(h)
            if not row:
                self._json({"paid": False}); return
            email, sats, token, lang = row
            if token:
                self._json({"paid": True, "token": token}); return
            try:
                pay = phx("/payments/incoming/" + h)
            except Exception:
                self._json({"paid": False}); return
            if pay.get("isPaid") and int(pay.get("receivedSat", 0)) >= int(sats):
                token = sign_license(email)
                order_set_token(h, token)                  # une seule fois (NULL -> set)
                send_license_email(email, token, lang)     # best-effort : reçu e-mail (langue détectée)
                self._json({"paid": True, "token": token})
            elif pay.get("isExpired"):
                self._json({"paid": False, "expired": True})
            else:
                self._json({"paid": False})
        else:
            self._json({"error": "not found"}, 404)

    def do_POST(self):
        u = urllib.parse.urlparse(self.path)
        if u.path != "/buy/create":
            self._json({"error": "not found"}, 404); return
        try:
            n = int(self.headers.get("Content-Length", 0))
            body = json.loads(self.rfile.read(n) or b"{}")
            email = str(body.get("email", "")).strip()
            if not EMAIL_RE.match(email):
                self._json({"error": "email invalide"}, 400); return
            lang = detect_lang(self.headers.get("Accept-Language"))
            sats = eur_to_sat(PRICE_EUR)
            inv = phx("/createinvoice", {"amountSat": sats, "description": "Souffleuse - licence",
                                         "expirySeconds": EXPIRY_S})
            h, bolt11 = inv["paymentHash"], inv["serialized"]
            order_create(h, email, sats, lang)
            self._json({"hash": h, "bolt11": bolt11, "sats": sats, "expires_in": EXPIRY_S,
                        "qr": qr_svg("lightning:" + bolt11)})
        except Exception:
            self._json({"error": "creation impossible"}, 500)

    def log_message(self, *a):
        pass

if __name__ == "__main__":          # importable (tests) sans démarrer le serveur
    ThreadingHTTPServer(LISTEN, H).serve_forever()
