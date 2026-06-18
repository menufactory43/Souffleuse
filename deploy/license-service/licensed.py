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
TEST_SATS = None                   # ⚠️ OVERRIDE DE TEST : facture ce montant fixe en sats
                                   # (ignore PRICE_EUR/taux). Mettre a None pour revenir au prix reel.
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
        "intro": "Votre licence Souffleuse Studio est prête. Activez-la en un clic, ou copiez la clé ci-dessous.",
        "keyLabel": "Votre clé de licence",
        "copyHint": "Astuce : triple-cliquez la clé (ou appui long sur mobile) pour tout sélectionner.",
        "activateBtn": "Activer dans Souffleuse",
        "activateNote": "Souffleuse doit être installé sur ce Mac. Le bouton ouvre l'app et active la clé automatiquement.",
        "steps": "Activation manuelle",
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
        "intro": "Your Souffleuse Studio licence is ready. Activate it in one click, or copy the key below.",
        "keyLabel": "Your licence key",
        "copyHint": "Tip: triple-click the key (or long-press on mobile) to select it all.",
        "activateBtn": "Activate in Souffleuse",
        "activateNote": "Souffleuse must be installed on this Mac. The button opens the app and activates the key automatically.",
        "steps": "Manual activation",
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
    # Le bouton « Activer » est un deep link souffleuse://activate?key=… : un clic
    # ouvre l'app et active la cle. Fallback : cle copiable a la main juste au-dessus
    # (un vrai bouton « copier » est impossible en e-mail — JS bloque par les clients).
    deeplink = "souffleuse://activate?key=" + urllib.parse.quote(token, safe="")
    return (
        '<table width="100%" cellpadding="0" cellspacing="0" role="presentation" '
        'style="background:#f3efe7;padding:32px 12px;font-family:Georgia,\'Times New Roman\',serif;">'
        '<tr><td align="center">'
        '<table width="520" cellpadding="0" cellspacing="0" role="presentation" '
        'style="max-width:520px;background:#fbf8f2;border:1px solid #e2d8c6;border-radius:16px;overflow:hidden;">'
        # En-tete
        '<tr><td style="padding:34px 36px 22px;border-bottom:1px solid #efe7d8;">'
        '<div style="font-size:27px;font-weight:bold;color:#8c2b21;letter-spacing:.01em;">Souffleuse</div>'
        f'<div style="font-style:italic;color:#6b6052;font-size:14px;margin-top:5px;">{s["tagline"]}</div>'
        '</td></tr>'
        # Corps : message + cle
        '<tr><td style="padding:26px 36px 6px;">'
        f'<p style="color:#1a1613;font-size:16px;font-weight:bold;margin:0 0 6px;">{s["hi"]}</p>'
        f'<p style="color:#3a342c;font-size:15px;line-height:1.55;margin:0 0 20px;">{s["intro"]}</p>'
        f'<div style="color:#8c2b21;font-weight:bold;font-size:11px;text-transform:uppercase;'
        f'letter-spacing:.07em;margin:0 0 7px;">{s["keyLabel"]}</div>'
        '<div style="font-family:Menlo,Consolas,monospace;font-size:14px;line-height:1.5;word-break:break-all;'
        'background:#ffffff;border:2px solid #8c2b21;border-radius:10px;padding:16px;color:#1a1613;'
        f'-webkit-user-select:all;user-select:all;">{token}</div>'
        f'<div style="color:#8a7f70;font-size:12px;margin:7px 0 0;">{s["copyHint"]}</div>'
        # Bouton deep link (un clic = activation)
        '<table cellpadding="0" cellspacing="0" role="presentation" style="margin:22px 0 4px;">'
        '<tr><td style="border-radius:10px;background:#8c2b21;">'
        f'<a href="{deeplink}" style="display:inline-block;padding:14px 28px;'
        'font-family:Georgia,serif;font-size:15px;font-weight:bold;color:#ffffff;'
        f'text-decoration:none;border-radius:10px;">{s["activateBtn"]} &rarr;</a>'
        '</td></tr></table>'
        f'<div style="color:#8a7f70;font-size:12px;margin:6px 0 0;">{s["activateNote"]}</div>'
        '</td></tr>'
        # Activation manuelle (fallback)
        '<tr><td style="padding:20px 36px 0;">'
        f'<div style="color:#8c2b21;font-weight:bold;font-size:11px;text-transform:uppercase;'
        f'letter-spacing:.07em;margin:0 0 8px;">{s["steps"]}</div>'
        '<ol style="color:#3a342c;font-size:14px;line-height:1.5;margin:0;padding-left:20px;">'
        f'<li style="margin:5px 0;">{s["s1"]}</li>'
        f'<li style="margin:5px 0;">{s["s2"]}</li>'
        f'<li style="margin:5px 0;">{s["s3"]}</li></ol>'
        f'<p style="color:#6b6052;font-size:13px;line-height:1.5;margin:20px 0 0;">{s["keep"]}</p>'
        '</td></tr>'
        # Pied
        '<tr><td style="padding:22px 36px 30px;">'
        '<hr style="border:none;border-top:1px solid #efe7d8;margin:0 0 14px;">'
        f'<div style="color:#8a7f70;font-size:12px;">souffleuse.app &middot; {s["foot"]}</div>'
        '</td></tr>'
        '</table></td></tr></table>'
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

# --- Page de checkout (localisée FR/EN via Accept-Language) ---
PAGE_STR = {
    "fr": {
        "title": "Souffleuse — licence",
        "sub1": "Licence complète — achat unique, paiement Lightning.",
        "emailLabel": "Votre e-mail (votre licence y sera rattachée)",
        "emailPh": "vous@exemple.fr",
        "buyHtml": 'Acheter — <span class="price">39 &euro;</span>',
        "payNote": "Paiement en bitcoin (Lightning). La clé de licence s'affiche dès réception.",
        "pay2": 'Payez <span class="price">39 &euro;</span>',
        "lnlink": "Ouvrir dans un portefeuille",
        "copyInvoice": "Copier la facture",
        "wait": "En attente du paiement&hellip;",
        "regen": "Régénérer la facture",
        "thanksOk": "&#10003; Merci !",
        "tokenSub": "Votre clé de licence. Activez-la en un clic, ou copiez-la pour la coller dans Souffleuse (Réglages &rarr; Studio).",
        "activateKey": "Activer dans Souffleuse",
        "activateNote": "Souffleuse doit être installé sur ce Mac.",
        "copyKey": "Copier la clé",
        "keepNote": "Cette clé est rattachée à votre e-mail. Gardez-la précieusement.",
        "footSmall": "souffleuse.app — 100% sur votre Mac",
        "locale": "fr",
        "js": {"invalidEmail": "E-mail invalide", "creating": "Création de la facture…",
               "waiting": "En attente du paiement…", "expired": "Facture expirée.",
               "expiresIn": "Expire dans ", "copied": "Copié !", "errorPrefix": "Erreur : ",
               "buyPlain": "Acheter — 39 €"},
    },
    "en": {
        "title": "Souffleuse — licence",
        "sub1": "Full licence — one-time purchase, Lightning payment.",
        "emailLabel": "Your email (your licence will be tied to it)",
        "emailPh": "you@example.com",
        "buyHtml": 'Buy — <span class="price">&euro;39</span>',
        "payNote": "Payment in bitcoin (Lightning). Your licence key appears on receipt.",
        "pay2": 'Pay <span class="price">&euro;39</span>',
        "lnlink": "Open in a wallet",
        "copyInvoice": "Copy the invoice",
        "wait": "Waiting for payment&hellip;",
        "regen": "Regenerate invoice",
        "thanksOk": "&#10003; Thank you!",
        "tokenSub": "Your licence key. Activate it in one click, or copy it to paste into Souffleuse (Settings &rarr; Studio).",
        "activateKey": "Activate in Souffleuse",
        "activateNote": "Souffleuse must be installed on this Mac.",
        "copyKey": "Copy the key",
        "keepNote": "This key is tied to your email. Keep it safe.",
        "footSmall": "souffleuse.app — 100% on your Mac",
        "locale": "en",
        "js": {"invalidEmail": "Invalid email", "creating": "Creating invoice…",
               "waiting": "Waiting for payment…", "expired": "Invoice expired.",
               "expiresIn": "Expires in ", "copied": "Copied!", "errorPrefix": "Error: ",
               "buyPlain": "Buy — €39"},
    },
}

def build_page(lang: str) -> str:
    s = PAGE_STR.get(lang, PAGE_STR["fr"])
    html = PAGE_TEMPLATE
    repl = {
        "{{lang}}": s["locale"], "{{title}}": s["title"], "{{sub1}}": s["sub1"],
        "{{emailLabel}}": s["emailLabel"], "{{emailPh}}": s["emailPh"], "{{buyHtml}}": s["buyHtml"],
        "{{payNote}}": s["payNote"], "{{pay2}}": s["pay2"], "{{lnlink}}": s["lnlink"],
        "{{copyInvoice}}": s["copyInvoice"], "{{wait}}": s["wait"], "{{regen}}": s["regen"],
        "{{thanksOk}}": s["thanksOk"], "{{tokenSub}}": s["tokenSub"], "{{copyKey}}": s["copyKey"],
        "{{activateKey}}": s["activateKey"], "{{activateNote}}": s["activateNote"],
        "{{keepNote}}": s["keepNote"], "{{footSmall}}": s["footSmall"], "{{locale}}": s["locale"],
        "{{ljson}}": json.dumps(s["js"]),
    }
    for k, v in repl.items():
        html = html.replace(k, v)
    return html

PAGE_TEMPLATE = r"""<!doctype html><html lang="{{lang}}"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>{{title}}</title><style>
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
a.btn{display:block;text-align:center;text-decoration:none;margin-top:16px;padding:12px;border-radius:8px;
background:var(--ox);color:#fff;font-size:15px;font-weight:600}
button.sec{background:#fff;color:var(--ox);border:1px solid var(--ox)}
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
<h1>Souffleuse</h1><p class="sub">{{sub1}}</p>
<label for="email">{{emailLabel}}</label>
<input id="email" type="email" placeholder="{{emailPh}}" autocomplete="email">
<button id="buy">{{buyHtml}}</button>
<p class="muted" style="margin-top:14px">{{payNote}}</p>
</div>
<div id="step2" class="hide">
<h1>{{pay2}}</h1><p class="sub" id="amt"></p>
<div class="qr" id="qr"></div>
<a class="ln" id="lnlink" href="#">{{lnlink}}</a>
<details style="margin-top:10px"><summary class="muted">{{copyInvoice}}</summary>
<div class="inv" id="inv"></div></details>
<p class="muted" id="timer" style="margin-top:14px"></p>
<p class="muted" id="wait">{{wait}}</p>
<button id="regen" class="hide">{{regen}}</button>
</div>
<div id="step3" class="hide">
<div class="ok">{{thanksOk}}</div>
<p class="sub">{{tokenSub}}</p>
<div class="tok" id="token"></div>
<a class="btn" id="activate" href="#">{{activateKey}}</a>
<button id="copy" class="sec">{{copyKey}}</button>
<p class="muted" style="margin-top:8px">{{activateNote}}</p>
<p class="muted" style="margin-top:12px">{{keepNote}}</p>
</div>
<small style="display:block;margin-top:18px;text-align:center">{{footSmall}}</small>
</div>
<script>
const LOCALE="{{locale}}"; const L={{ljson}};
const $=s=>document.querySelector(s);
let email=null, hash=null, pollT=null, cdT=null, left=0;
function tick(){
  if(left<=0){expired();return;}
  const m=Math.floor(left/60), s=String(left%60).padStart(2,"0");
  $("#timer").textContent=L.expiresIn+m+":"+s; left--;
}
function expired(){clearInterval(cdT);clearInterval(pollT);
  $("#timer").textContent=L.expired;$("#wait").textContent="";$("#regen").classList.remove("hide");}
async function createInvoice(){
  $("#regen").classList.add("hide");$("#wait").textContent=L.creating;
  const r=await fetch("/buy/create",{method:"POST",headers:{"Content-Type":"application/json"},body:JSON.stringify({email})});
  const d=await r.json(); if(d.error) throw new Error(d.error);
  hash=d.hash; $("#qr").innerHTML=d.qr; $("#inv").textContent=d.bolt11;
  $("#lnlink").href="lightning:"+d.bolt11; $("#amt").textContent=d.sats.toLocaleString(LOCALE)+" sats";
  $("#wait").textContent=L.waiting;
  left=d.expires_in||900; clearInterval(cdT); tick(); cdT=setInterval(tick,1000);
  clearInterval(pollT); pollT=setInterval(poll,2500); poll();
}
async function poll(){
  if(!hash)return;
  const d=await (await fetch("/buy/status?h="+hash)).json();
  if(d.paid&&d.token){clearInterval(pollT);clearInterval(cdT);
    $("#token").textContent=d.token;
    $("#activate").href="souffleuse://activate?key="+encodeURIComponent(d.token);
    $("#step2").classList.add("hide");$("#step3").classList.remove("hide");}
  else if(d.expired){expired();}
}
$("#buy").onclick=async()=>{
  const e=$("#email").value.trim();
  if(!/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(e)){alert(L.invalidEmail);return;}
  email=e;$("#buy").disabled=true;
  $("#step1").classList.add("hide");$("#step2").classList.remove("hide");
  try{await createInvoice();}
  catch(err){alert(L.errorPrefix+err.message);
    $("#step1").classList.remove("hide");$("#step2").classList.add("hide");
    $("#buy").disabled=false;$("#buy").textContent=L.buyPlain;}
};
$("#regen").onclick=()=>createInvoice().catch(err=>alert(L.errorPrefix+err.message));
$("#copy").onclick=()=>{const b=$("#copy"),o=b.textContent;
  navigator.clipboard.writeText($("#token").textContent);b.textContent=L.copied;
  setTimeout(()=>{b.textContent=o;},2000);};
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
            self._html(build_page(detect_lang(self.headers.get("Accept-Language"))))
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
            sats = TEST_SATS if TEST_SATS is not None else eur_to_sat(PRICE_EUR)
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
