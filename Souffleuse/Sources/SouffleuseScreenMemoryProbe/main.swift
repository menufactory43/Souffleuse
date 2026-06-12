import AppKit
import CoreGraphics
import Foundation
import ImageIO
import SouffleuseContext
import Vision

// Souffleuse Screen Memory Probe — pire cas Brave
//
// Question à trancher : la « mémoire photographique de frappe » (snapshot OCR
// d'une fenêtre quittée → rappel lexical au moment où l'utilisateur retape un
// fait) est-elle atteignable avec un seuil de confiance agressif (rappel
// quasi-exact uniquement, silence sinon) sur de l'OCR bruité de page web ?
//
// Protocole :
//   1. Écrit une fixture HTML (faits plantés + distracteurs) dans /tmp,
//      l'ouvre dans Brave (pire cas : arbre AX dormant → OCR seule source,
//      page dense → bruit maximal pour le rappel lexical).
//   2. Capture la fenêtre Brave (ScreenCapturer prod, downscale 1280) puis
//      OCR pleine page (Vision .accurate, PAS le VisionOCR prod qui est
//      tronqué à 500 chars + clustering bottom — la mémoire veut tout).
//   3. Indexe les lignes OCR (BM25, sans embeddings) et rejoue 20 débuts de
//      frappe : 10 mi-fait (l'utilisateur retape le début du fait), 4 amorce
//      sémantique (le label seul), 6 négatives (fait absent → silence requis).
//   4. Gate strict : tir uniquement si le doc top-1 contient TOUS les tokens
//      de l'amorce (le dernier en préfixe — token en cours de frappe).
//
// Verdict : GO si mi-fait ≥ 8/10 corrects ET 0 faux tir sur les négatives.
//
// Usage :
//   swift run SouffleuseScreenMemoryProbe              # capture Brave live
//   swift run SouffleuseScreenMemoryProbe --image x.png # OCR d'un screenshot
//   SOUFFLEUSE_SMP_NO_OPEN=1 …                          # ne pas (r)ouvrir Brave

// MARK: - Fixture

let fixtureHTML = """
<!DOCTYPE html><html lang="fr"><head><meta charset="utf-8">
<title>Boîte de réception (3) — atelier-mail.fr</title>
<style>
 body { font-family: -apple-system, Helvetica, sans-serif; margin: 0; display: flex; font-size: 15px; color: #1c1c1e; }
 #side { width: 250px; background: #f2f2f7; padding: 14px; border-right: 1px solid #d1d1d6; }
 #side h3 { font-size: 13px; color: #8e8e93; text-transform: uppercase; }
 .mail { padding: 9px 6px; border-bottom: 1px solid #e5e5ea; font-size: 13px; }
 .mail b { display: block; }
 #main { flex: 1; padding: 26px 38px; max-width: 760px; }
 h1 { font-size: 21px; }
 .meta { color: #636366; font-size: 13px; margin-bottom: 18px; }
 table { border-collapse: collapse; margin: 14px 0; }
 td { border: 1px solid #d1d1d6; padding: 7px 12px; }
 .foot { margin-top: 26px; color: #8e8e93; font-size: 12.5px; }
</style></head><body>
<div id="side">
 <h3>Boîte de réception</h3>
 <div class="mail"><b>Fnac</b> Votre commande CMD-99102 est expédiée — suivi disponible.</div>
 <div class="mail"><b>Doctolib</b> Rappel : dentiste jeudi 19 juin 14h, Dr Perrin.</div>
 <div class="mail"><b>EDF</b> Votre facture de 89,40 € est disponible.</div>
 <div class="mail"><b>Atelier Verre &amp; Bois</b> Confirmation de commande et livraison.</div>
 <div class="mail"><b>Marc</b> Re: compte-rendu réunion produit du 21 mai.</div>
</div>
<div id="main">
 <h1>Confirmation de votre commande — Atelier Verre &amp; Bois</h1>
 <div class="meta">De : Camille Lacombe &lt;camille.lacombe@orange.fr&gt; — à moi — 11 juin 2026, 18:42</div>
 <p>Bonjour,</p>
 <p>Merci pour votre achat. Votre commande CMD-58214 (dossier n° 2024-EX-077)
 est confirmée. La table basse sera livrée à l'adresse de livraison suivante :
 14 rue des Lilas, 75011 Paris.</p>
 <p>Le créneau de pose est fixé au rendez-vous suivant : mardi 17 juin à 9h30.
 Notre artisan vous appellera la veille.</p>
 <table>
  <tr><td>Total de la commande</td><td>1 249,90 €</td></tr>
  <tr><td>Numéro de suivi Colissimo</td><td>8R 102 358 6172 W</td></tr>
  <tr><td>IBAN pour le solde</td><td>FR76 3000 4028 3798 7654 3210 943</td></tr>
 </table>
 <p>Pour toute question, vous pouvez me joindre directement au 06 52 18 47 93,
 ou nous appeler au service client : 01 44 78 12 30 (lun-ven, 9h-18h).</p>
 <p>Bien cordialement,<br>Camille Lacombe — Atelier Verre &amp; Bois</p>
 <div class="foot">Atelier Verre &amp; Bois SARL — 8 passage du Chantier, 75012 Paris —
 SIRET 532 081 449 00027 — TVA FR23532081449. Conditions générales de vente sur notre site.</div>
</div>
</body></html>
"""

// MARK: - Requêtes

enum Regime: String { case midFact = "mi-fait", leadIn = "amorce", negative = "négatif" }

struct Query {
    let label: String
    /// Le préfixe que l'utilisateur est en train de taper dans une autre app.
    let typed: String
    /// Sous-chaîne (normalisée alphanum) qui doit figurer dans le doc top-1
    /// pour compter correct. Vide pour les négatives (silence attendu).
    let expect: String
    let regime: Regime
}

let queries: [Query] = [
    // Mi-fait : le préfixe contient le début du fait — le moment ghost réel.
    Query(label: "adresse",  typed: "c'est au 14 rue",                 expect: "des Lilas 75011",      regime: .midFact),
    Query(label: "commande", typed: "la réf c'est CMD-5",             expect: "58214",                regime: .midFact),
    Query(label: "rdv",      typed: "rdv mardi 17",                   expect: "juin à 9h30",          regime: .midFact),
    Query(label: "email",    typed: "écris à camille.lacombe@",       expect: "orange",               regime: .midFact),
    Query(label: "tel",      typed: "son numéro : 06 52",             expect: "18 47 93",             regime: .midFact),
    Query(label: "dossier",  typed: "le dossier n° 2024-EX",          expect: "077",                  regime: .midFact),
    Query(label: "montant",  typed: "ça coûte 1 249",                 expect: "90",                   regime: .midFact),
    Query(label: "suivi",    typed: "numéro de suivi 8R 102",         expect: "358 6172",             regime: .midFact),
    Query(label: "iban",     typed: "l'IBAN FR76 3000",               expect: "4028 3798",            regime: .midFact),
    Query(label: "nom",      typed: "elle s'appelle Camille Lac",     expect: "Lacombe",              regime: .midFact),
    // Amorce sémantique : aucun token du fait, seulement le label/contexte.
    Query(label: "adresse-label", typed: "l'adresse de livraison c'est",  expect: "14 rue des Lilas",  regime: .leadIn),
    Query(label: "tel-label",     typed: "tu peux l'appeler au",          expect: "06 52 18 47 93",    regime: .leadIn),
    Query(label: "rdv-label",     typed: "le rendez-vous est prévu",      expect: "mardi 17 juin",     regime: .leadIn),
    Query(label: "total-label",   typed: "le total de la commande est de", expect: "1 249,90",         regime: .leadIn),
    // Négatives : le fait n'est pas à l'écran — un tir = faux positif.
    Query(label: "neg-vol",     typed: "le vol AF 1280",            expect: "", regime: .negative),
    Query(label: "neg-gmail",   typed: "son adresse gmail",         expect: "", regime: .negative),
    Query(label: "neg-devis",   typed: "le devis DEV-2071",         expect: "", regime: .negative),
    Query(label: "neg-reunion", typed: "réunion jeudi 26 juin à",   expect: "", regime: .negative),
    Query(label: "neg-promo",   typed: "le code promo NOEL25",      expect: "", regime: .negative),
    Query(label: "neg-ticket",  typed: "ticket #4582",              expect: "", regime: .negative),
]

// MARK: - Tokenisation & normalisation

let stopwords: Set<String> = [
    "le", "la", "les", "un", "une", "des", "de", "du", "d", "l", "c", "j", "n",
    "s", "qu", "que", "et", "ou", "a", "au", "aux", "en", "pour", "par", "sur",
    "dans", "avec", "ce", "cette", "ces", "son", "sa", "ses", "est", "sont",
    "il", "elle", "on", "je", "tu", "y", "ne", "pas", "plus", "the", "an",
    "of", "to", "in", "at", "is", "are", "it", "for", "and", "or",
    "c'est", "appelle",
]

func fold(_ s: String) -> String {
    s.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "fr_FR"))
        .lowercased()
}

func tokenize(_ s: String) -> [String] {
    fold(s).components(separatedBy: CharacterSet.alphanumerics.inverted)
        .filter { !$0.isEmpty }
}

/// Squelette alphanum pour le test de containment (robuste aux espaces OCR).
func skeleton(_ s: String) -> String {
    tokenize(s).joined()
}

/// Tokens de contenu d'un préfixe tapé : stopwords retirés, 6 derniers max.
/// Le DERNIER token est le mot en cours de frappe → matching en préfixe.
func cueTokens(from typed: String) -> [String] {
    let toks = tokenize(typed).filter { !stopwords.contains($0) }
    return Array(toks.suffix(6))
}

// MARK: - OCR pleine page

struct OCRLine {
    let text: String
    let box: CGRect  // Vision, normalisé, origine bas-gauche
}

func ocrFullPage(_ image: CGImage) async throws -> [OCRLine] {
    try await withCheckedThrowingContinuation { (cont: CheckedContinuation<[OCRLine], Error>) in
        let request = VNRecognizeTextRequest { request, error in
            if let error { cont.resume(throwing: error); return }
            let obs = request.results as? [VNRecognizedTextObservation] ?? []
            let lines = obs.compactMap { o -> OCRLine? in
                guard let t = o.topCandidates(1).first?.string else { return nil }
                return OCRLine(text: t, box: o.boundingBox)
            }
            cont.resume(returning: lines)
        }
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["fr-FR", "en-US"]
        request.usesLanguageCorrection = true
        do {
            try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        } catch {
            cont.resume(throwing: error)
        }
    }
}

/// Regroupe les observations en lignes visuelles (même bande y), ordre de
/// lecture, puis produit les docs : chaque ligne + fenêtres de 2 lignes
/// consécutives (un fait peut être coupé entre le label et la valeur).
func buildDocs(from lines: [OCRLine]) -> [String] {
    guard !lines.isEmpty else { return [] }
    let heights = lines.map(\.box.height).sorted()
    let tolerance = max(heights[heights.count / 2] * 0.6, 0.004)
    var groups: [[OCRLine]] = []
    for line in lines.sorted(by: { $0.box.midY > $1.box.midY }) {
        if var last = groups.last, let ref = last.first,
           abs(ref.box.midY - line.box.midY) < tolerance {
            last.append(line)
            groups[groups.count - 1] = last
        } else {
            groups.append([line])
        }
    }
    let visualLines = groups.map { group in
        group.sorted { $0.box.minX < $1.box.minX }.map(\.text).joined(separator: " ")
    }
    var docs = visualLines
    if visualLines.count > 1 {
        for i in 0..<(visualLines.count - 1) {
            docs.append(visualLines[i] + " " + visualLines[i + 1])
        }
    }
    return docs
}

// MARK: - Index BM25 + gate strict

struct Index {
    let docs: [String]
    let docTokens: [[String]]
    let avgLen: Double

    init(docs: [String]) {
        self.docs = docs
        self.docTokens = docs.map(tokenize)
        let total = docTokens.reduce(0) { $0 + $1.count }
        self.avgLen = docs.isEmpty ? 1 : Double(total) / Double(docs.count)
    }

    private func matches(_ tokens: [String], _ term: String, asPrefix: Bool) -> Int {
        tokens.reduce(0) { acc, t in
            acc + ((asPrefix ? t.hasPrefix(term) : t == term) ? 1 : 0)
        }
    }

    /// BM25 (k1=1.2, b=0.75). Le dernier terme matche en préfixe (mot en
    /// cours de frappe).
    func score(cue: [String], doc index: Int) -> Double {
        let tokens = docTokens[index]
        guard !tokens.isEmpty else { return 0 }
        let n = Double(docs.count)
        var s = 0.0
        for (i, term) in cue.enumerated() {
            let isLast = i == cue.count - 1
            let tf = Double(matches(tokens, term, asPrefix: isLast))
            guard tf > 0 else { continue }
            let df = Double((0..<docs.count).count {
                matches(docTokens[$0], term, asPrefix: isLast) > 0
            })
            let idf = log((n - df + 0.5) / (df + 0.5) + 1)
            let norm = tf * 2.2 / (tf + 1.2 * (0.25 + 0.75 * Double(tokens.count) / avgLen))
            s += idf * norm
        }
        return s
    }

    func top(cue: [String], k: Int = 3) -> [(index: Int, score: Double)] {
        (0..<docs.count)
            .map { ($0, score(cue: cue, doc: $0)) }
            .sorted { $0.1 > $1.1 }
            .prefix(k)
            .map { (index: $0.0, score: $0.1) }
    }

    /// Gate strict v2 : top-1 contient les 2 tokens de QUEUE de l'amorce
    /// (le dernier en préfixe — mot en cours de frappe). Les tokens plus en
    /// amont sont les mots de l'utilisateur (« ça coûte », « écris à ») qui
    /// ne figurent pas à l'écran — exiger leur présence (v1, tous tokens)
    /// bloquait 4/10 cas mi-fait dont le doc top-1 était pourtant correct.
    /// La queue, elle, est le début du fait retapé : exigence exacte.
    func strictGateFires(cue: [String], doc index: Int) -> Bool {
        guard cue.count >= 2 else { return false }
        let tail = Array(cue.suffix(2))
        let tokens = docTokens[index]
        for (i, term) in tail.enumerated() {
            if matches(tokens, term, asPrefix: i == tail.count - 1) == 0 { return false }
        }
        return true
    }
}

// MARK: - Chargement image (--image)

func loadImage(path: String) -> CGImage? {
    let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
    guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
    return CGImageSourceCreateImageAtIndex(src, 0, nil)
}

// MARK: - Main

func err(_ s: String) { FileHandle.standardError.write(Data((s + "\n").utf8)) }
setbuf(stdout, nil)
setbuf(stderr, nil)

// Connexion au window server — sans ça, ScreenCaptureKit asserte
// (CGS_REQUIRE_INIT) dans un exécutable CLI sans NSApplication.
_ = NSApplication.shared

let braveBundleID = "com.brave.Browser"
let fixturePath = "/tmp/souffleuse-screen-memory-fixture.html"
let ocrDumpPath = "/tmp/souffleuse-screen-memory-ocr.txt"
let args = CommandLine.arguments
let env = ProcessInfo.processInfo.environment

let image: CGImage
if let flagIdx = args.firstIndex(of: "--image"), args.count > flagIdx + 1 {
    guard let loaded = loadImage(path: args[flagIdx + 1]) else {
        err("Impossible de charger l'image \(args[flagIdx + 1])"); exit(1)
    }
    err("[smp] image fournie : \(args[flagIdx + 1])")
    image = loaded
} else {
    try fixtureHTML.write(toFile: fixturePath, atomically: true, encoding: .utf8)
    err("[smp] fixture écrite : \(fixturePath)")

    guard ScreenCapturer.hasPermission() else {
        err("""
        [smp] Pas de permission Screen Recording pour ce process.
        → Accorde-la au terminal dans Réglages > Confidentialité > Enregistrement de l'écran,
          ou passe un screenshot : swift run SouffleuseScreenMemoryProbe --image capture.png
        """)
        ScreenCapturer.requestPermission()
        exit(2)
    }

    if env["SOUFFLEUSE_SMP_NO_OPEN"] == nil {
        let open = Process()
        open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        open.arguments = ["-a", "Brave Browser", fixturePath]
        try open.run()
        open.waitUntilExit()
        err("[smp] fixture ouverte dans Brave, attente du rendu (5 s)…")
        try await Task.sleep(for: .seconds(5))
    }

    let capturer = ScreenCapturer()
    do {
        let capture = try await capturer.capture(bundleID: braveBundleID)
        err("[smp] capture Brave OK (\(capture.image.width)×\(capture.image.height), downscale prod 1280)")
        image = capture.image
    } catch {
        err("[smp] capture Brave échouée : \(error)"); exit(2)
    }
}

let lines = try await ocrFullPage(image)
let docs = buildDocs(from: lines)
try docs.joined(separator: "\n").write(toFile: ocrDumpPath, atomically: true, encoding: .utf8)
err("[smp] OCR : \(lines.count) observations → \(docs.count) docs (lignes + fenêtres). Dump : \(ocrDumpPath)")
guard !docs.isEmpty else { err("[smp] OCR vide — rien à indexer."); exit(2) }

let index = Index(docs: docs)

struct Tally { var fired = 0; var correct = 0; var total = 0 }
var tallies: [Regime: Tally] = [.midFact: Tally(), .leadIn: Tally(), .negative: Tally()]
var rows: [String] = []

print("─── Screen Memory Probe — pire cas Brave ───")
print(String(format: "%-14@ %-8@ %5@ %6@ %5@  %@", "requête" as NSString, "régime" as NSString,
             "tir" as NSString, "score" as NSString, "ok" as NSString, "doc top-1" as NSString))

for q in queries {
    let cue = cueTokens(from: q.typed)
    let top = index.top(cue: cue)
    let best = top.first ?? (index: 0, score: 0)
    let fires = index.strictGateFires(cue: cue, doc: best.index)
    let doc = docs[best.index]
    let correct: Bool
    switch q.regime {
    case .negative:
        correct = !fires  // silence attendu
    default:
        correct = fires && skeleton(doc).contains(skeleton(q.expect))
    }
    tallies[q.regime]?.total += 1
    if fires { tallies[q.regime]?.fired += 1 }
    if correct { tallies[q.regime]?.correct += 1 }

    let snippet = String(doc.prefix(58))
    let mark = correct ? "✓" : "✗"
    rows.append("\(q.label): tir=\(fires) score=\(String(format: "%.1f", best.score)) \(mark)")
    print(String(format: "%-14@ %-8@ %5@ %6.1f %5@  %@",
                 q.label as NSString, q.regime.rawValue as NSString,
                 (fires ? "TIR" : "—") as NSString, best.score,
                 mark as NSString, snippet as NSString))
}

let mid = tallies[.midFact]!
let lead = tallies[.leadIn]!
let neg = tallies[.negative]!
let falseFires = neg.total - neg.correct

print("""

─── Synthèse ───
mi-fait  (rappel au gate strict) : \(mid.correct)/\(mid.total)
amorce sémantique (informatif)   : \(lead.correct)/\(lead.total)
négatives : faux tirs            : \(falseFires)/\(neg.total)
""")

let verdict: String
if mid.correct >= 8 && falseFires == 0 {
    verdict = "GO — le rappel quasi-exact + silence-sinon tient sur l'OCR Brave."
} else if mid.correct >= 6 && falseFires <= 1 {
    verdict = "PARTIEL — signal réel mais gate/OCR à durcir avant d'aller plus loin."
} else {
    verdict = "NO-GO — l'OCR bruité ou le gate lexical ne tiennent pas le pire cas."
}
print("VERDICT : \(verdict)")
