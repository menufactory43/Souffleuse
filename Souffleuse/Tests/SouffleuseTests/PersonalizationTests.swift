import CryptoKit
import Foundation
import Testing
import SouffleuseTyping
import SouffleuseCorpus
@testable import SouffleusePersonalization

// MARK: - Helpers

private func tempStoreDir(_ tag: String = UUID().uuidString) -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("souffleuse-tests-\(tag)", isDirectory: true)
    try? FileManager.default.removeItem(at: dir)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

private func tempStoreURL(_ tag: String = UUID().uuidString) -> URL {
    tempStoreDir(tag).appendingPathComponent("history.db")
}

private func makeStore(_ tag: String = UUID().uuidString) -> (TypingHistoryStore, URL, SymmetricKey) {
    let url = tempStoreURL(tag)
    try? FileManager.default.removeItem(at: url)
    let key = SymmetricKey(size: .bits256)
    return (TypingHistoryStore(fileURL: url, testKey: key), url, key)
}

private func makeEntry(_ accepted: String, _ ctx: String = "ctx") -> TypingHistoryEntry {
    TypingHistoryEntry(timestamp: Date(), contextBefore: ctx, accepted: accepted, bundleID: "com.test")
}

// MARK: - SecretHeuristic

@Test func secretHeuristicFlagsLongTokens() {
    #expect(SecretHeuristic.looksLikeSecret("aXz9Kpq7vBnM2Lqw4Rt6"))
    #expect(SecretHeuristic.looksLikeSecret("ghp_1234567890abcdefghij"))
}

@Test func secretHeuristicAcceptsHumanText() {
    #expect(!SecretHeuristic.looksLikeSecret("Bonjour Gabriel"))
    #expect(!SecretHeuristic.looksLikeSecret("À bientôt et bonne journée"))
    #expect(!SecretHeuristic.looksLikeSecret("hello world"))
}

@Test func secretHeuristicContextTailTrimsToLastSentence() {
    let tail = SecretHeuristic.contextTail(prefix: "Hello. World goes on")
    #expect(tail == "World goes on")
}

// MARK: - pruneLowQuality (V2 corpus hygiene)

@Test func pruneLowQualityDropsShortSingleTokensKeepsRealPhrases() async {
    let (store, _, _) = makeStore()
    // Short single-token word-completer residue → should be pruned.
    await store.append(makeEntry("ton"))      // 3 chars, single token
    await store.append(makeEntry("aux"))      // 3 chars, single token
    await store.append(makeEntry("frais"))    // 5 chars, single token (boundary, pruned)
    // Real value → must be KEPT.
    await store.append(makeEntry("fiscal"))                 // 6 chars single token > 5 → keep
    await store.append(makeEntry("de travail à manches"))   // multi-word → keep
    await store.append(makeEntry("Bonjour Madame"))         // multi-word → keep

    let before = await store.count()
    let deleted = await store.pruneLowQuality()
    let remaining = await store.allEntries().map { $0.accepted }

    #expect(deleted == 3)                          // ton, aux, frais
    #expect(before - remaining.count == 3)
    #expect(!remaining.contains("ton"))
    #expect(!remaining.contains("aux"))
    #expect(!remaining.contains("frais"))
    #expect(remaining.contains("fiscal"))          // single token but >5 → kept
    #expect(remaining.contains("de travail à manches"))
    #expect(remaining.contains("Bonjour Madame"))
}

@Test func pruneLowQualityIsIdempotent() async {
    let (store, _, _) = makeStore()
    await store.append(makeEntry("ton"))
    await store.append(makeEntry("Bonjour Madame"))
    _ = await store.pruneLowQuality()
    let second = await store.pruneLowQuality()   // nothing short-single left
    #expect(second == 0)
    let remaining = await store.allEntries().map { $0.accepted }
    #expect(remaining == ["Bonjour Madame"])
}

@Test func secretHeuristicContextTailFallsBackToSuffix() {
    let prefix = String(repeating: "a", count: 200)
    let tail = SecretHeuristic.contextTail(prefix: prefix, maxChars: 50)
    #expect(tail.count == 50)
}

// MARK: - TypingHistoryStore

@Test func historyEncryptedRoundTrip() async throws {
    let (store, url, key) = makeStore("rt")
    await store.append(makeEntry("Bonjour"))
    await store.append(makeEntry("À bientôt"))
    await store.append(makeEntry("Merci"))

    let reloaded = TypingHistoryStore(fileURL: url, testKey: key)
    let entries = await reloaded.allEntries()
    #expect(entries.count == 3)
    #expect(entries.map(\.accepted) == ["Bonjour", "À bientôt", "Merci"])

    // File must not be plaintext-readable.
    let raw = try Data(contentsOf: url)
    let asString = String(data: raw, encoding: .utf8) ?? ""
    #expect(!asString.contains("Bonjour"))

    await reloaded.clear()
}

@Test func historyFifoPurgeAtCap() async throws {
    // Validate FIFO purge against a small temporary cap rather than inserting
    // 50k rows. Uses the test-only purge seam.
    let (store, _, _) = makeStore("ring")
    let cap = 100
    let overshoot = 50
    for i in 0..<(cap + overshoot) {
        await store.append(makeEntry("phrase numéro \(i)"))
    }
    await store.purgeToCapForTesting(cap)
    let count = await store.count()
    #expect(count == cap)
    let entries = await store.allEntries()
    // First `overshoot` should have been dropped (FIFO by id).
    #expect(entries.first?.accepted == "phrase numéro \(overshoot)")
    #expect(entries.last?.accepted == "phrase numéro \(cap + overshoot - 1)")
    await store.clear()
}

@Test func historyBlocksHighEntropyAcceptances() async throws {
    let (store, _, _) = makeStore("entropy")
    await store.append(makeEntry("aXz9Kpq7vBnM2Lqw4Rt6"))
    await store.append(makeEntry("Bonjour"))
    let entries = await store.allEntries()
    #expect(entries.count == 1)
    #expect(entries.first?.accepted == "Bonjour")
    await store.clear()
}

@Test func historyDecryptCorruptFileResetsToEmpty() async throws {
    let url = tempStoreURL("corrupt")
    try? FileManager.default.removeItem(at: url)
    // Write garbage that won't decrypt.
    try Data((0..<256).map { _ in UInt8.random(in: 0...255) }).write(to: url)
    let store = TypingHistoryStore(fileURL: url, testKey: SymmetricKey(size: .bits256))
    let count = await store.count()
    #expect(count == 0)
    // Subsequent appends still work (file is rewritten).
    await store.append(makeEntry("after recovery"))
    let entries = await store.allEntries()
    #expect(entries.map(\.accepted) == ["after recovery"])
    await store.clear()
}

@Test func historyEncryptedAtRestNoSQLiteMagic() async throws {
    let (store, url, _) = makeStore("magic")
    await store.append(makeEntry("Bonjour le monde"))
    // Force a flush/close so all pages hit disk.
    let n = await store.count()
    #expect(n == 1)

    let raw = try Data(contentsOf: url)
    #expect(raw.count >= 16)
    // A plaintext SQLite db begins with the 16-byte magic "SQLite format 3\0".
    let magic = Array("SQLite format 3\u{0}".utf8)
    let header = Array(raw.prefix(16))
    #expect(header != magic)        // encrypted: header is NOT the magic
    let asString = String(data: raw, encoding: .utf8) ?? ""
    #expect(!asString.contains("Bonjour"))  // payload not plaintext
    await store.clear()
}

@Test func historyMigratesFromLegacyAESBlob() async throws {
    let dir = tempStoreDir("migrate")
    let dbURL = dir.appendingPathComponent("history.db")
    let aesURL = dir.appendingPathComponent("history.aes")
    let key = SymmetricKey(size: .bits256)

    // Seed a legacy AES-GCM JSON blob exactly as the old store wrote it.
    let legacy = [
        TypingHistoryEntry(timestamp: Date(), contextBefore: "ctx1", accepted: "ancien un", bundleID: "com.a"),
        TypingHistoryEntry(timestamp: Date(), contextBefore: "ctx2", accepted: "ancien deux", bundleID: nil),
    ]
    let plaintext = try JSONEncoder().encode(legacy)
    let sealed = try AES.GCM.seal(plaintext, using: key)
    try sealed.combined!.write(to: aesURL)

    // New store opens the .db, sees the sibling .aes, migrates with same key.
    let store = TypingHistoryStore(fileURL: dbURL, testKey: key)
    let entries = await store.allEntries()
    #expect(entries.map(\.accepted) == ["ancien un", "ancien deux"])

    // Legacy blob renamed (not deleted), so it is no longer at the source path.
    #expect(!FileManager.default.fileExists(atPath: aesURL.path))
    #expect(FileManager.default.fileExists(atPath: aesURL.appendingPathExtension("migrated").path))

    // Idempotent: a second store sees no source file, count unchanged.
    let store2 = TypingHistoryStore(fileURL: dbURL, testKey: key)
    let count2 = await store2.count()
    #expect(count2 == 2)
    await store2.clear()
}

@Test func historyPrefixLookup() async throws {
    let (store, _, _) = makeStore("prefix")
    await store.append(TypingHistoryEntry(timestamp: Date(), contextBefore: "Bonjour ", accepted: "Gabriel", bundleID: nil))
    await store.append(TypingHistoryEntry(timestamp: Date(), contextBefore: "Bonjour ", accepted: "tout le monde", bundleID: nil))
    await store.append(TypingHistoryEntry(timestamp: Date(), contextBefore: "Au revoir ", accepted: "et merci", bundleID: nil))
    let matches = await store.entriesMatchingContext("bonjour")
    #expect(matches.count == 2)
    #expect(Set(matches.map(\.accepted)) == ["Gabriel", "tout le monde"])
    await store.clear()
}

@Test func historyRejectsTooShortAcceptance() async throws {
    let (store, _, _) = makeStore("short")
    await store.append(makeEntry("ok"))   // len 2 → rejected
    await store.append(makeEntry("oui"))  // len 3 → kept
    let entries = await store.allEntries()
    #expect(entries.map(\.accepted) == ["oui"])
    await store.clear()
}

// MARK: - Fragment gate (corpus pollution prevention)

@Suite("TypingHistoryStore fragment gate")
struct FragmentGateTests {
    @Test("lone consonant + space = fragment (rejected)")
    func rejectsConsonantFragment() {
        #expect(TypingHistoryStore.looksLikeFragment("s de manger"))
        #expect(TypingHistoryStore.looksLikeFragment("t es là"))
        #expect(TypingHistoryStore.looksLikeFragment("l a dit"))
    }

    @Test("genuine one-letter French words kept")
    func keepsStandaloneWords() {
        #expect(!TypingHistoryStore.looksLikeFragment("à demain"))
        #expect(!TypingHistoryStore.looksLikeFragment("y aller"))
        #expect(!TypingHistoryStore.looksLikeFragment("a fait beau"))
    }

    @Test("normal text and uncommon vocabulary kept")
    func keepsNormalAndVocab() {
        #expect(!TypingHistoryStore.looksLikeFragment("de manger des sushis"))
        #expect(!TypingHistoryStore.looksLikeFragment("Cocotypist arrive bientôt"))
        #expect(!TypingHistoryStore.looksLikeFragment("merguez"))
    }
}

// MARK: - Garde d'admission unique (parité disque ↔ mémoire)

/// Verrouille `TypingHistoryStore.admissionRejection` — la décision désormais
/// PARTAGÉE par `append` (disque) et `PredictorViewModel.ingestAccepted` (corpus
/// mémoire). Avant, la mémoire n'appliquait que la garde secret ; ces tests
/// fixent les 4 gardes au même endroit pour qu'aucun fragment / mot tronqué /
/// payload court accepté ne puisse plus entrer en mémoire alors que le disque le
/// rejette.
@Suite("TypingHistoryStore.admissionRejection — garde d'admission unique")
struct AdmissionRejectionTests {
    private let typo = TypoDetector()

    private func reject(_ ctx: String, _ acc: String) -> TypingHistoryStore.AdmissionRejection? {
        TypingHistoryStore.admissionRejection(contextBefore: ctx, accepted: acc, typoDetector: typo)
    }

    @Test("prose normale admise (nil)")
    func admitsRealProse() {
        #expect(reject("", "Puis-je avoir votre relevé Binance ?") == nil)
        #expect(reject("je vais ", "manger des sushis ce soir") == nil)
    }

    @Test("payload trimmé < 3 caractères rejeté")
    func rejectsTooShort() {
        #expect(reject("", "  f") == .tooShort)
        #expect(reject("", "ok") == .tooShort)
    }

    @Test("secret-like rejeté")
    func rejectsSecret() {
        #expect(reject("", "Tr0ub4dour3xK9pLmQ7zW") == .secretLike)
    }

    @Test("fragment live-consume rejeté")
    func rejectsFragment() {
        #expect(reject("", "s de manger") == .fragment)
    }

    @Test("mot tronqué mid-glue rejeté ; complétion valide admise")
    func rejectsTruncatedButKeepsValid() {
        // "vérifi" invalide, accepted = run nu sans suite → tronqué.
        #expect(reject("je vais vér", "ifi") == .truncatedFragment)
        // "premiere"+"entrée" : "entrée" valide en standalone → next-word, admis.
        #expect(reject("la premiere ", "entrée du menu") == nil)
    }

    @Test("artefact machine rejeté ; prose FR/EN légitime admise")
    func rejectsArtifactKeepsBilingualProse() {
        // Artefacts capturés du champ (.prose) → .artifact.
        #expect(reject("", "Binance-Historial-de-transacciones UTC (4).numbers") == .artifact)
        #expect(reject("", "deenakaan@gmail.com") == .artifact)
        #expect(reject("", "https://dashboard.stripe.com/subscriptions") == .artifact)
        #expect(reject("", "2025-04-07 07:37:15") == .artifact)
        // Prose légitime — FR ET EN (user bilingue) — jamais touchée par le gate.
        #expect(reject("", "If he can find the missing transaction, we will correct it.") == nil)
        #expect(reject("", "Puis-je avoir votre relevé Binance ?") == nil)
    }

    @Test("looksLikeArtifact — signatures positives et négatives")
    func looksLikeArtifactSignatures() {
        // Positifs : URL, email, domaine, fichiers, low-letter, CSV.
        #expect(TypingHistoryStore.looksLikeArtifact("https://souffleuse.app"))
        #expect(TypingHistoryStore.looksLikeArtifact("gabriel.turpin@waltio.co"))
        #expect(TypingHistoryStore.looksLikeArtifact("hdk.op-mgmt.net/accounts"))
        #expect(TypingHistoryStore.looksLikeArtifact("Resumen (27).pdf"))
        #expect(TypingHistoryStore.looksLikeArtifact("Inventario - 2026-06-09T171741.825.xlsx"))
        #expect(TypingHistoryStore.looksLikeArtifact("03-06-2026"))
        #expect(TypingHistoryStore.looksLikeArtifact("\"ormazioni\",\"Stato\""))
        // Négatifs : vraie prose FR et EN, vocabulaire métier, ponctuation normale.
        #expect(!TypingHistoryStore.looksLikeArtifact("Le transfert n'a pas été effectué."))
        #expect(!TypingHistoryStore.looksLikeArtifact("For me it's a good solution."))
        #expect(!TypingHistoryStore.looksLikeArtifact("Waltio est un logiciel de gestion des impôts."))
    }

    @Test("ordre des gardes : secret prime sur fragment (parité append)")
    func gateOrderMatchesDisk() {
        // Un secret qui commencerait aussi par un fragment-like doit sortir en
        // .secretLike (même ordre que l'ancien append : longueur→secret→fragment→tronqué).
        #expect(reject("", "x AbCdEf0123456789Ghij") == .secretLike)
    }
}

// MARK: - SecretHeuristic.redact (caviardage des secrets embarqués)

@Suite("SecretHeuristic.redact")
struct SecretRedactionTests {
    private let mask = SecretHeuristic.redactionPlaceholder

    @Test("paires credential clé=valeur / clé: valeur — valeur masquée, clé gardée")
    func redactsCredentialPairs() {
        let r1 = SecretHeuristic.redact("export API_KEY=sk-abcDEF1234567890xyz")
        #expect(r1.contains("API_KEY="))
        #expect(r1.contains(mask))
        #expect(!r1.contains("sk-abcDEF1234567890xyz"))

        let r2 = SecretHeuristic.redact("password: hunter2supersecret")
        #expect(r2.contains("password:"))
        #expect(r2.contains(mask))
        #expect(!r2.contains("hunter2supersecret"))

        // .env multi-lignes : chaque valeur sensible masquée, les clés survivent.
        let env = SecretHeuristic.redact("DB_PASSWORD=p@ssW0rd!\nCLIENT_SECRET=qwertyuiopASDF1234")
        #expect(env.contains("DB_PASSWORD="))
        #expect(env.contains("CLIENT_SECRET="))
        #expect(!env.contains("p@ssW0rd!"))
        #expect(!env.contains("qwertyuiopASDF1234"))
    }

    @Test("tokens secrets isolés — préfixes fournisseurs et runs ≥16 alnum")
    func redactsStandaloneTokens() {
        // Préfixes connus, même courts.
        #expect(SecretHeuristic.redact("voici ma clé ghp_1234567890abcdefXYZ merci").contains(mask))
        #expect(!SecretHeuristic.redact("voici ma clé ghp_1234567890abcdefXYZ merci").contains("ghp_"))
        // JWT.
        #expect(SecretHeuristic.redact("Authorization Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9").contains(mask))
        // Run ≥16 alnum (UUID sans tirets / SHA).
        #expect(SecretHeuristic.redact("token aXz9Kpq7vBnM2Lqw4Rt6 fin").contains(mask))
    }

    @Test("identité sur de la prose normale (FR/EN, identifiants courts)")
    func leavesNormalProseIntact() {
        let inputs = [
            "Bonjour Gabriel, comment ça va aujourd'hui ?",
            "For me it's a good solution.",
            "Le rapport fiscal est prêt, merci de le valider.",
            "On se voit à 14h30 pour le point d'équipe.",
            "Mon numéro de bureau est le A-204.",
        ]
        for input in inputs {
            #expect(SecretHeuristic.redact(input) == input)
        }
    }

    @Test("mot purement alphabétique très long : conservé (pas un secret)")
    func keepsLongAlphabeticWords() {
        // Régression : le run ≥16 doit MÊLER lettres ET chiffres pour être masqué ;
        // un mot français/allemand interminable n'est pas un secret.
        #expect(SecretHeuristic.redact("anticonstitutionnellement") == "anticonstitutionnellement")
        #expect(SecretHeuristic.redact("Donaudampfschifffahrtsgesellschaft") == "Donaudampfschifffahrtsgesellschaft")
        // Mais un run alphanumérique mixte ≥16 reste masqué.
        #expect(SecretHeuristic.redact("aXz9Kpq7vBnM2Lqw4Rt6").contains(mask))
    }

    @Test("valeur credential avec guillemet interne ou entre guillemets : masquée en entier")
    func redactsQuotedAndEmbeddedQuoteValues() {
        // Guillemet interne dans une valeur nue : pas de fuite du fragment après le guillemet.
        let r1 = SecretHeuristic.redact("password=ab\"cd")
        #expect(!r1.contains("cd"))
        #expect(r1.contains(mask))
        // Valeur entre guillemets avec espaces : masquée d'un bloc.
        let r2 = SecretHeuristic.redact("password=\"correct horse battery\"")
        #expect(!r2.contains("horse"))
        #expect(r2.contains(mask))
    }

    @Test("idempotence : redact(redact(x)) == redact(x)")
    func isIdempotent() {
        let inputs = [
            "API_KEY=sk-abcDEF1234567890xyz",
            "password: hunter2supersecret rest of sentence",
            "ghp_1234567890abcdefXYZ standalone",
            "token aXz9Kpq7vBnM2Lqw4Rt6",
            // Régression : valeur entre guillemets COLLÉE à du texte (token="a"more)
            // — la valeur doit être consommée d'un bloc, donc stable au 2e tour.
            "token=\"a\"more",
            "secret=\"x\"yztail",
        ]
        for input in inputs {
            let once = SecretHeuristic.redact(input)
            #expect(SecretHeuristic.redact(once) == once)
        }
    }

    @Test("préfixe Slack resserré : « xoxo » (affection) n'est PAS caviardé")
    func keepsXoxoAffection() {
        #expect(SecretHeuristic.redact("À demain, xoxo") == "À demain, xoxo")
        #expect(SecretHeuristic.redact("bisous xoxox") == "bisous xoxox")
        // Mais un vrai token Slack (avec tiret) reste masqué.
        #expect(SecretHeuristic.redact("token xoxb-12345-abcde").contains(mask))
    }

    @Test("placeholder ne re-déclenche ni .secretLike ni .artifact")
    func placeholderIsAdmissionSafe() {
        let td = TypoDetector()
        let redacted = SecretHeuristic.redact("ma clé est API_KEY=sk-abcDEF1234567890xyz voilà")
        #expect(TypingHistoryStore.admissionRejection(
            contextBefore: "", accepted: redacted, typoDetector: td) == nil)
    }

    @Test("store : une entrée à secret embarqué est persistée caviardée")
    func storeRedactsOnAppend() async {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SecretRedactionTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = TypingHistoryStore(fileURL: dir.appendingPathComponent("history.db"),
                                       testKey: SymmetricKey(size: .bits256))
        await store.append(TypingHistoryEntry(
            timestamp: Date(),
            contextBefore: "mon fichier de config",
            accepted: "le secret est API_KEY=sk-abcDEF1234567890xyz à garder",
            bundleID: nil))
        let entries = await store.allEntries()
        #expect(entries.count == 1)
        if let stored = entries.first {
            #expect(stored.accepted.contains(SecretHeuristic.redactionPlaceholder))
            #expect(!stored.accepted.contains("sk-abcDEF1234567890xyz"))
        }
    }
}
