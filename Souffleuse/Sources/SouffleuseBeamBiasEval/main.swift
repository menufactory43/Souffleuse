import Foundation
import SouffleuseCore
import SouffleuseLlama
import SouffleuseLog

// Souffleuse Beam Bias Eval v2 — PROD-FIDÈLE (2026-06-12, post-revue adverse).
//
// Différences avec la v1 (qui répliquait l'éval greedy ×3-copies) :
//   - corpus DÉDUPLIQUÉ : 3 phrases DISTINCTES par mot appris, partageant une
//     collocation de 3-6 mots — la seule forme qu'un store prod peut produire
//     (TypingHistoryStore.append → deleteDuplicate) ;
//   - mots-cibles : 6 noms propres improbables ET 10 mots communs spécifiques
//     (l'objectif produit : « des mots spécifiques, pas forcément des noms
//     propres ») ;
//   - adverses : 12 near-miss sur FRAGMENTS FRÉQUENTS de collocations (le
//     régime que le repli compté rend dangereux) — 0 injection exigé ;
//   - moteur : repli compté par entrées distinctes + barème + score découplé
//     (BeamGhostEngine.applyCorpusBias, flag SOUFFLEUSE_BEAM_BIAS).
//
// Cible go/no-go (objectif utilisateur) : recall ≥ 50% (« le mot sort une fois
// sur deux quand on le force »), sur-injection 0/12, latence ≈ baseline.
// Sweep : SOUFFLEUSE_BEAM_PROMOTE_MATCHLEN (défaut 5).
//
// Usage : swift run -c release SouffleuseBeamBiasEval

func err(_ s: String) { FileHandle.standardError.write((s + "\n").data(using: .utf8)!) }

// ─────────────────────────────────────────────────────────────────────────────
// Fixtures PROD-FIDÈLES — corpus DÉDUPLIQUÉ (parité `TypingHistoryStore.append`
// → `deleteDuplicate` : un vrai store ne contient que des phrases DISTINCTES).
//
// Géométrie visée pour `LlamaCorpusSuffixArray.longestMatch` :
// chaque mot-cible est appris via 3 phrases DISTINCTES qui ne partagent que la
// COLLOCATION (3-6 mots) précédant le mot. Le plus long suffixe commun de la
// sonde présent dans le corpus est donc la collocation elle-même :
//   • match = collocation  → count == 3 (une occurrence par phrase), share 1.0
//   • tout match PLUS LONG → spécifique à UNE phrase (count 1)
// C'est exactement la distribution d'un corpus utilisateur réel — contrairement
// à l'ancien eval (×3 copies identiques) où le longest-match retournait count 3
// sur la phrase entière, un régime que la prod ne produit jamais.
//
// Les sondes finissent sur un mot complet, sans espace final (même profil que
// l'éval existante : healing OFF, le ghost attendu commence par " " + gold).
// ─────────────────────────────────────────────────────────────────────────────

/// Un mot appris : 3 phrases distinctes le contenant après la même collocation,
/// une sonde NOUVELLE finissant par la collocation, et le gold attendu.
struct LearnedCase: Sendable {
    /// Gold : le mot que le ghost doit produire (début du ghost = " " + term).
    let term: String
    /// 3-6 mots, suffixe commun aux 3 phrases ET à la sonde, précède `term`.
    let collocation: String
    /// 3 phrases distinctes (8-20 mots) — le corpus appris, zéro doublon.
    let sentences: [String]
    /// Phrase NOUVELLE (hors corpus), finit EXACTEMENT par `collocation`.
    let probe: String
}

/// Near-miss adverse : la sonde finit par un FRAGMENT de collocation (1-2 mots
/// fréquents) dans un contexte où injecter le mot appris serait une
/// sur-injection. Garde-fou anti-over-trigger du beam.
struct AdversarialCase: Sendable {
    let probe: String
    /// Le terme appris qui NE DOIT PAS apparaître dans le ghost.
    let forbidden: String
    /// Le fragment de collocation partagé avec le corpus (documentation).
    let fragment: String
}

// ── 16 cas APPRIS : 6 noms propres improbables + 10 mots communs spécifiques
//    (registre support client / fiscalité crypto / quotidien pro — Fiduxio). ───
let learnedCases: [LearnedCase] = [

    // ══ Noms propres improbables (marques, prénoms) ══

    .init(
        term: "Fiduxio",
        collocation: "directement depuis votre espace",
        sentences: [
            "Vous pouvez exporter le rapport fiscal complet directement depuis votre espace Fiduxio en deux clics.",
            "La synchronisation des transactions échouées se relance directement depuis votre espace Fiduxio, onglet comptes.",
            "Pour vérifier le calcul des plus-values, reconnectez-vous directement depuis votre espace Fiduxio avant la clôture annuelle.",
        ],
        probe: "Le justificatif réclamé par l'administration fiscale se télécharge directement depuis votre espace"
    ),
    .init(
        term: "Trade Republic",
        collocation: "mon courtier de référence reste",
        sentences: [
            "Pour mes versements programmés en ETF, mon courtier de référence reste Trade Republic depuis trois ans.",
            "Malgré des frais de change un peu lourds, mon courtier de référence reste Trade Republic.",
            "Côté actions fractionnées européennes, mon courtier de référence reste Trade Republic, faute de mieux.",
        ],
        probe: "Après avoir comparé les tarifs de tout le marché cette année, mon courtier de référence reste"
    ),
    .init(
        term: "Bitpanda",
        collocation: "l'API en lecture seule de",
        sentences: [
            "Nous récupérons l'historique complet des trades via l'API en lecture seule de Bitpanda, sans droit de retrait.",
            "Les soldes de vos portefeuilles se synchronisent chaque nuit grâce à l'API en lecture seule de Bitpanda.",
            "Le support a reconnecté votre compte hier soir en régénérant l'API en lecture seule de Bitpanda.",
        ],
        probe: "Vos récompenses de staking remonteront automatiquement dès que vous aurez branché l'API en lecture seule de"
    ),
    .init(
        term: "Finary",
        collocation: "mon patrimoine global sur",
        sentences: [
            "Je consolide mon patrimoine global sur Finary pour suivre l'allocation entre crypto et immobilier.",
            "Chaque dimanche soir, je mets à jour mon patrimoine global sur Finary, petit rituel obsessionnel.",
            "Depuis janvier je suis mon patrimoine global sur Finary plutôt que dans mon vieux tableur.",
        ],
        probe: "Avant le rendez-vous avec la banquière, j'ai pris le temps d'actualiser mon patrimoine global sur"
    ),
    .init(
        term: "Anaëlle",
        collocation: "je transmets votre dossier à",
        sentences: [
            "Pour la déclaration des comptes à l'étranger, je transmets votre dossier à Anaëlle dès ce soir.",
            "Comme convenu au téléphone, je transmets votre dossier à Anaëlle, notre spécialiste des cas complexes.",
            "Vu le nombre d'airdrops concernés, je transmets votre dossier à Anaëlle pour une relecture complète.",
        ],
        probe: "Votre situation dépasse mon périmètre de support, je transmets votre dossier à"
    ),
    .init(
        term: "Maïwenn",
        collocation: "le point hebdo avec",
        sentences: [
            "Je décale le point hebdo avec Maïwenn à jeudi, elle est en formation mardi.",
            "On a validé la nouvelle roadmap du support pendant le point hebdo avec Maïwenn ce matin.",
            "Pense à préparer les chiffres de tickets résolus pour le point hebdo avec Maïwenn.",
        ],
        probe: "Je note les questions encore en suspens et je les garde pour le point hebdo avec"
    ),

    // ══ Mots communs spécifiques (dans le vocabulaire du modèle, mais qu'il ne
    //    choisirait jamais spontanément — registre pro/juridique/finance FR) ══

    .init(
        term: "huitaine",
        collocation: "vous parviendra sous",
        sentences: [
            "Le remboursement de votre abonnement annuel vous parviendra sous huitaine sur le compte d'origine.",
            "L'attestation fiscale corrigée vous parviendra sous huitaine par retour de courrier électronique.",
            "La réponse définitive du service comptable vous parviendra sous huitaine, au plus tard vendredi.",
        ],
        probe: "Le virement correspondant au trop-perçu de l'an dernier vous parviendra sous"
    ),
    .init(
        term: "moratoire",
        collocation: "nous a accordé un",
        sentences: [
            "Bonne nouvelle, l'administration fiscale nous a accordé un moratoire de six mois sur les pénalités.",
            "Après le recours gracieux, le SIE nous a accordé un moratoire jusqu'à la fin du trimestre.",
            "Le juge nous a accordé un moratoire le temps que la plateforme en faillite rende les fonds.",
        ],
        probe: "Compte tenu de votre bonne foi évidente, le comptable public nous a accordé un"
    ),
    .init(
        term: "rétrocession",
        collocation: "une commission de",
        sentences: [
            "Le partenaire apporteur d'affaires touche une commission de rétrocession sur chaque abonnement annuel vendu.",
            "Vérifiez que le mandat de gestion ne prévoit pas une commission de rétrocession cachée.",
            "Notre conseiller en gestion de patrimoine reverse une commission de rétrocession trimestrielle, c'est contractuel.",
        ],
        probe: "Sur ce produit structuré, le distributeur prélève au passage une commission de"
    ),
    .init(
        term: "quittance",
        collocation: "joindre votre dernière",
        sentences: [
            "Pour le justificatif de domicile, merci de joindre votre dernière quittance de loyer au dossier.",
            "La banque exige de joindre votre dernière quittance avant de débloquer les fonds du prêt.",
            "Pensez à joindre votre dernière quittance, sans quoi le bailleur écartera votre candidature.",
        ],
        probe: "Pour finaliser la vérification d'identité de votre compte, vous devrez joindre votre dernière"
    ),
    .init(
        term: "affacturage",
        collocation: "le poste clients par",
        sentences: [
            "Pour lisser la trésorerie, la direction a fini par financer le poste clients par affacturage.",
            "La startup couvre le poste clients par affacturage depuis sa levée de fonds avortée.",
            "Le DAF refuse de financer le poste clients par affacturage, il juge les frais prohibitifs.",
        ],
        probe: "Vu des délais de paiement qui filent vers quatre-vingt-dix jours, nous financerons le poste clients par"
    ),
    .init(
        term: "nantissement",
        collocation: "son assurance-vie en",
        sentences: [
            "La banque a exigé de placer son assurance-vie en nantissement pour garantir le crédit professionnel.",
            "Il a préféré mettre son assurance-vie en nantissement plutôt que de vendre ses titres.",
            "Avant de débloquer la ligne de crédit, le prêteur réclame son assurance-vie en nantissement.",
        ],
        probe: "Pour obtenir le prêt relais sans hypothèque, elle a finalement remis son assurance-vie en"
    ),
    .init(
        term: "forclusion",
        collocation: "sous peine de",
        sentences: [
            "Vous devez contester l'avis d'imposition dans les trente jours, sous peine de forclusion définitive.",
            "Le recours doit être déposé avant le 31 décembre, sous peine de forclusion.",
            "L'avocate insiste : répondez à la mise en demeure sous peine de forclusion du dossier.",
        ],
        probe: "La réclamation contentieuse doit impérativement partir avant la fin du mois, sous peine de"
    ),
    .init(
        term: "échéancier",
        collocation: "mettre en place un",
        sentences: [
            "Le service recouvrement accepte de mettre en place un échéancier sur douze mois maximum.",
            "Pour étaler la flat tax, vous pouvez mettre en place un échéancier auprès de votre SIE.",
            "On a réussi à mettre en place un échéancier juste avant l'envoi de la mise en demeure.",
        ],
        probe: "Si le montant réclamé dépasse vos capacités du moment, le Trésor public peut mettre en place un"
    ),
    .init(
        term: "mainlevée",
        collocation: "a obtenu la",
        sentences: [
            "Après paiement intégral de la dette, notre avocate a obtenu la mainlevée de la saisie.",
            "Le greffe confirme qu'on a obtenu la mainlevée hier, les fonds sont de nouveau disponibles.",
            "Il a obtenu la mainlevée du séquestre en remboursant le solde par anticipation.",
        ],
        probe: "Excellente nouvelle pour votre client, l'huissier confirme qu'il a obtenu la"
    ),
    .init(
        term: "soulte",
        collocation: "compensé par une",
        sentences: [
            "L'échange des deux lots sera compensé par une soulte de quinze mille euros chez le notaire.",
            "Dans le partage successoral, le déséquilibre est compensé par une soulte versée par l'aîné.",
            "Le swap immobilier est compensé par une soulte, elle-même imposable au titre de la plus-value.",
        ],
        probe: "Si les deux cryptoactifs échangés n'ont pas la même valeur, l'écart est compensé par une"
    ),
]

// ── 12 cas ADVERSES near-miss : la sonde finit par un fragment FRÉQUENT d'une
//    collocation apprise, dans un contexte où le terme serait une sur-injection.
//    Le suffix array matche le fragment — pour la plupart count 3, share 1.0
//    (le régime le plus tentant pour la promotion) : seul le plancher matchLen
//    protège. « sous » (6 phrases, distribution mixte huitaine/peine) et « par »
//    (12 phrases, très diffus) testent en plus le régime à distribution mixte. ─
let adversarialCases: [AdversarialCase] = [
    // Fragment 1 mot, ultra-fréquent : « reste » précède "Trade Republic" ×3.
    .init(probe: "Malgré la correction du marché, mon objectif de performance pour cette année reste",
          forbidden: "Trade Republic", fragment: "reste"),
    // Fragment 2 mots : « votre espace » précède "Fiduxio" ×3 — vicieux, share 1.0.
    .init(probe: "Vous pouvez ranger les cartons d'archives de l'ancien bureau dans votre espace",
          forbidden: "Fiduxio", fragment: "votre espace"),
    // Fragment 3 mots (vicieux assumé) : « votre dossier à » sans le verbe appris.
    .init(probe: "Le greffe du tribunal vous demande d'adresser votre dossier à",
          forbidden: "Anaëlle", fragment: "votre dossier à"),
    // Fragment 1 mot : « sous » — dans le corpus il précède "huitaine" ET "peine".
    .init(probe: "Le serveur de préproduction tourne encore sous",
          forbidden: "huitaine", fragment: "sous"),
    // Fragment 2 mots : « global sur » hors finance perso.
    .init(probe: "Le rapport mesure l'impact du réchauffement global sur",
          forbidden: "Finary", fragment: "global sur"),
    // Fragment 2 mots (vicieux) : « accordé un » avec un autre sujet (lui ≠ nous).
    .init(probe: "Le jury du concours lui a finalement accordé un",
          forbidden: "moratoire", fragment: "accordé un"),
    // Fragment 1 mot, parmi les plus fréquents du français : « avec ».
    .init(probe: "Je finalise la présentation client de demain avec",
          forbidden: "Maïwenn", fragment: "avec"),
    // Fragment 2 mots : « votre dernière » en clôture de ticket support.
    .init(probe: "Nous avons bien pris en compte votre dernière",
          forbidden: "quittance", fragment: "votre dernière"),
    // Fragment 2 mots : « commission de » au sens administratif, pas financier.
    .init(probe: "Le dossier passe le mois prochain devant la commission de",
          forbidden: "rétrocession", fragment: "commission de"),
    // Fragment 1 mot : « par » en fin de phrase logistique.
    .init(probe: "Le colis contenant votre commande a été expédié hier par",
          forbidden: "affacturage", fragment: "par"),
    // Fragment 2 mots : « par une » en récit quotidien.
    .init(probe: "La démonstration en visio a été interrompue par une",
          forbidden: "soulte", fragment: "par une"),
    // Fragment 2 mots, piège lexical : « peine de » (≠ « sous peine de »).
    .init(probe: "Avant d'escalader le ticket au niveau deux, prenez la peine de",
          forbidden: "forclusion", fragment: "peine de"),
]

// ── Corpus prod-fidèle : phrases DISTINCTES uniquement (le store déduplique
//    via deleteDuplicate — zéro répétition, contrairement à l'ancien ×3). ─────
let corpus: [String] = learnedCases.flatMap { $0.sentences }


// ── Sanity au boot : fidélité des fixtures (échoue fort si un fixture dérive). ─
for c in learnedCases {
    precondition(c.sentences.count == 3, "\(c.term): il faut 3 phrases distinctes")
    precondition(Set(c.sentences).count == 3, "\(c.term): phrases dupliquées")
    for s in c.sentences {
        precondition(s.contains(c.collocation + " " + c.term),
                     "\(c.term): collocation+terme absents de « \(s) »")
        let n = s.split(separator: " ").count
        precondition((8...20).contains(n), "\(c.term): phrase hors 8-20 mots (\(n))")
    }
    precondition(c.probe.hasSuffix(c.collocation),
                 "\(c.term): la sonde ne finit pas par la collocation")
    precondition(!c.probe.contains(c.term), "\(c.term): le gold fuit dans la sonde")
}
precondition(Set(corpus).count == corpus.count, "corpus non dédupliqué (parité deleteDuplicate)")
for a in adversarialCases {
    precondition(!a.probe.contains(a.forbidden), "adverse: terme interdit présent dans la sonde")
    precondition(a.probe.hasSuffix(a.fragment), "adverse: la sonde ne finit pas par le fragment")
    precondition(learnedCases.contains { $0.collocation.contains(a.fragment) },
                 "adverse: fragment « \(a.fragment) » absent de toute collocation apprise")
}

// ── Boot fidèle prod : poids dans LlamaEngine, beam EMPRUNTE (borrowModel) ───
let ggufPath: String = {
    if let p = ProcessInfo.processInfo.environment["SOUFFLEUSE_GGUF"], !p.isEmpty {
        return (p as NSString).expandingTildeInPath
    }
    return (("~/Library/Application Support/app.cotypist.Cotypist/Models/gemma-3-1b.i1-Q5_K_M.gguf") as NSString)
        .expandingTildeInPath
}()

let lender = LlamaEngine()
err("[beam-bias-v2] loading GGUF: \(ggufPath)")
guard await lender.load(modelPath: ggufPath, contextTokens: 4096) else {
    err("FATAL: could not load GGUF"); exit(1)
}
guard let borrowed = await lender.borrowModel() else { err("FATAL: borrowModel nil"); exit(1) }
let beam = BeamGhostEngine(config: .ghostCore())
guard await beam.load(borrowedModel: borrowed, contextTokens: 4096) else {
    err("FATAL: beam load failed"); exit(1)
}
await beam.setCorpus(corpus)
err("[beam-bias-v2] corpus: \(corpus.count) phrases DISTINCTES (\(learnedCases.count) mots ×3) — promoteMatchLen beam = \(ProcessInfo.processInfo.environment["SOUFFLEUSE_BEAM_PROMOTE_MATCHLEN"] ?? "5 (défaut)")")

func ghostText(_ lead: String) async -> (text: String, ms: Int) {
    let prompt = BeamGhostShaper.buildPrompt(customInstr: "", ctxPrefix: "", llmTail: lead)
    let r = await beam.ghost(prompt: prompt, requiredPrefix: "", maxWidth: 1)
    return (r.best?.ghost ?? "", r.elapsedMillis)
}

struct CondResult {
    var hits: [String] = []
    var misses: [(String, String)] = []
    var overInjections: [String] = []
    var latencies: [Int] = []
}

let gainScale = LlamaSampling.personalizationGainScale
let allTerms = learnedCases.map { $0.term.lowercased() }

func runCondition(strength: Float, label: String) async -> CondResult {
    await beam.setBiasStrength(strength)
    var res = CondResult()
    for c in learnedCases {
        let (out, ms) = await ghostText(c.probe)
        res.latencies.append(ms)
        if out.lowercased().contains(c.term.lowercased()) {
            res.hits.append(c.term)
        } else {
            res.misses.append((c.term, String(out.prefix(44))))
        }
    }
    for a in adversarialCases {
        let (out, ms) = await ghostText(a.probe)
        res.latencies.append(ms)
        let o = out.lowercased()
        for t in allTerms where o.contains(t) {
            res.overInjections.append("\(t) ← «…\(a.probe.suffix(28))» → «\(out.prefix(40))»")
        }
    }
    err("[beam-bias-v2] \(label) done")
    return res
}

let condA = await runCondition(strength: 0, label: "A (bias OFF)")
let condB = await runCondition(strength: 1.0 * gainScale, label: "B (bias ON)")

func mean(_ xs: [Int]) -> Int { xs.isEmpty ? 0 : xs.reduce(0, +) / xs.count }
let n = learnedCases.count
let na = adversarialCases.count

print("\n════════ Beam Bias Eval v2 — corpus PROD-FIDÈLE (dédupliqué, collocations) ════════")
print("  condition       recall        sur-injection   latence moy.")
print("  A bias OFF      \(condA.hits.count)/\(n)          \(condA.overInjections.count)/\(na)            \(mean(condA.latencies)) ms")
print("  B bias ON       \(condB.hits.count)/\(n)          \(condB.overInjections.count)/\(na)            \(mean(condB.latencies)) ms")
print("\n── Hits B ──")
print("  " + condB.hits.joined(separator: " · "))
print("\n── Manqués B ──")
for (t, out) in condB.misses { print("  ✗ \(t) ← «\(out)»") }
if !condB.overInjections.isEmpty {
    print("\n── ⚠ SUR-INJECTIONS B (chacune = no-go) ──")
    for o in condB.overInjections { print("  ⚠ \(o)") }
}
let go = condB.hits.count * 2 >= n && condB.overInjections.isEmpty
print("\nVERDICT : \(go ? "✅ GO" : "❌ NO-GO") — cible recall ≥ \((n + 1) / 2)/\(n) ET sur-injection 0/\(na)")
