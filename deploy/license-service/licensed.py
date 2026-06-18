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
    return c

def order_create(h, email, sats):
    c = _db(); c.execute("INSERT OR REPLACE INTO orders(hash,email,sats,token,created) VALUES(?,?,?,NULL,?)",
                         (h, email, sats, int(time.time()))); c.commit(); c.close()

def order_get(h):
    c = _db(); row = c.execute("SELECT email,sats,token FROM orders WHERE hash=?", (h,)).fetchone(); c.close()
    return row

def order_set_token(h, token):
    c = _db(); c.execute("UPDATE orders SET token=? WHERE hash=?", (token, h)); c.commit(); c.close()

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
            email, sats, token = row
            if token:
                self._json({"paid": True, "token": token}); return
            try:
                pay = phx("/payments/incoming/" + h)
            except Exception:
                self._json({"paid": False}); return
            if pay.get("isPaid") and int(pay.get("receivedSat", 0)) >= int(sats):
                token = sign_license(email)
                order_set_token(h, token)
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
            sats = eur_to_sat(PRICE_EUR)
            inv = phx("/createinvoice", {"amountSat": sats, "description": "Souffleuse - licence",
                                         "expirySeconds": EXPIRY_S})
            h, bolt11 = inv["paymentHash"], inv["serialized"]
            order_create(h, email, sats)
            self._json({"hash": h, "bolt11": bolt11, "sats": sats, "expires_in": EXPIRY_S,
                        "qr": qr_svg("lightning:" + bolt11)})
        except Exception:
            self._json({"error": "creation impossible"}, 500)

    def log_message(self, *a):
        pass

ThreadingHTTPServer(LISTEN, H).serve_forever()
