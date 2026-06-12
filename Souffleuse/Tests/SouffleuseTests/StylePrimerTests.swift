import Foundation
import SouffleuseCorpus
import Testing

@testable import SouffleuseCore

/// Couvre `StylePrimer` : détection de registre, filtre « pauvre en entités »,
/// accord au ton par app, verrou de cohérence de registre en `.neutral`,
/// réutilisation des invariants privacy du pool few-shot (cluster, `.prose`
/// only), bornes de longueur et plafond d'entrées.
@Suite("StylePrimer — sélection du style primer")
struct StylePrimerTests {

    private func prose(
        _ text: String,
        bundleID: String? = "com.apple.TextEdit",
        source: EntrySource = .prose
    ) -> TypingHistoryEntry {
        TypingHistoryEntry(
            timestamp: Date(),
            contextBefore: "",
            accepted: text,
            bundleID: bundleID,
            source: source
        )
    }

    // MARK: - Registre marqué

    @Test func registreTutoiement() {
        #expect(StylePrimer.markedTone("t'inquiète je gère, tu me dis ce soir") == .casual)
        #expect(StylePrimer.markedTone("je te renvoie ça avec ton dossier") == nil
            || StylePrimer.markedTone("je te renvoie ça avec ton dossier") == .casual)
    }

    @Test func registreVouvoiement() {
        #expect(StylePrimer.markedTone("je vous remercie de votre retour") == .formal)
    }

    @Test func registreNonMarque() {
        #expect(StylePrimer.markedTone("le dossier est prêt pour demain matin") == nil)
    }

    // MARK: - Pauvre en entités

    @Test func subjectPoorRejetteChiffres() {
        #expect(!StylePrimer.isSubjectPoor("je vous confirme la facture n° 2214 sous huitaine"))
    }

    @Test func subjectPoorRejetteNomPropreMiPhrase() {
        #expect(!StylePrimer.isSubjectPoor("on s'est éclatés à Biarritz hier soir"))
        #expect(!StylePrimer.isSubjectPoor("Bonjour Madame Morel, merci pour votre retour"))
    }

    @Test func subjectPoorAccepteProseNormale() {
        #expect(StylePrimer.isSubjectPoor("Je vous remercie de votre retour. Nous revenons vers vous rapidement."))
        #expect(StylePrimer.isSubjectPoor("ahah ouais carrément, on gère ça tranquille cette semaine"))
    }

    // MARK: - Accord de ton (le ton par défaut PAR APP pilote la sélection)

    @Test func tonFormelExclutLeTutoiement() {
        let entries = [
            prose("t'inquiète c'est tout bon, je te renvoie ça ce soir sans faute"),
            prose("je vous remercie de votre retour et reste à votre disposition"),
        ]
        let block = StylePrimer.block(from: entries, activeDomain: .other, tone: .formal)
        #expect(block == "je vous remercie de votre retour et reste à votre disposition")
    }

    @Test func tonCasualExclutLeVouvoiement() {
        let entries = [
            prose("je vous prie de bien vouloir patienter quelques jours"),
            prose("t'inquiète c'est tout bon, je te renvoie ça ce soir sans faute"),
        ]
        let block = StylePrimer.block(from: entries, activeDomain: .other, tone: .casual)
        #expect(block == "t'inquiète c'est tout bon, je te renvoie ça ce soir sans faute")
    }

    @Test func tonNeutreVerrouilleLePremierRegistreMarque() {
        // .neutral : pas de contrainte a priori, mais le PREMIER texte marqué
        // verrouille le registre — un primer mi-« tu » mi-« vous » brouille.
        let entries = [
            prose("t'inquiète c'est tout bon, je te renvoie ça ce soir sans faute"),
            prose("je vous remercie de votre retour et reste à votre disposition"),
            prose("ahah ouais carrément, on gère ça tranquille cette semaine"),
        ]
        let block = StylePrimer.block(from: entries, activeDomain: .other, tone: .neutral)
        let parts = block.components(separatedBy: "\n\n")
        #expect(parts.count == 2)
        #expect(parts[0].hasPrefix("t'inquiète"))
        #expect(parts[1].hasPrefix("ahah ouais"))
    }

    // MARK: - Invariants privacy hérités du pool few-shot

    @Test func proseDuChatNeFuitPasVersLeMail() {
        let entries = [
            prose("t'inquiète c'est tout bon, je te renvoie ça ce soir sans faute",
                  bundleID: "net.whatsapp.WhatsApp"),
        ]
        let block = StylePrimer.block(from: entries, activeDomain: .mail, tone: .neutral)
        #expect(block.isEmpty)
    }

    @Test func fragmentsAcceptExclus() {
        let entries = [
            prose("voilà une continuation acceptée assez longue pour passer",
                  source: .accept),
        ]
        let block = StylePrimer.block(from: entries, activeDomain: .other, tone: .neutral)
        #expect(block.isEmpty)
    }

    // MARK: - Bornes

    @Test func plafondDeuxEntreesEtDedup() {
        let texts = [
            "ahah ouais carrément, on gère ça tranquille cette semaine",
            "ahah ouais carrément, on gère ça tranquille cette semaine",   // dup
            "bon allez je file, on se tient au courant pour la suite hein",
            "franchement c'était une super soirée, merci encore pour tout",
        ]
        let block = StylePrimer.block(from: texts.map { prose($0) }, activeDomain: .other, tone: .casual)
        let parts = block.components(separatedBy: "\n\n")
        #expect(parts.count == 2)
        #expect(Set(parts).count == 2)
    }

    @Test func tropCourtOuTropLongExclu() {
        let tooShort = "ok ça marche"
        let tooLong = String(repeating: "très longue prose qui dépasse la borne haute ", count: 6)
        let block = StylePrimer.block(
            from: [prose(tooShort), prose(tooLong)], activeDomain: .other, tone: .neutral)
        #expect(block.isEmpty)
    }

    @Test func rienDEligibleRendVide() {
        #expect(StylePrimer.block(from: [], activeDomain: .other, tone: .neutral).isEmpty)
    }

    // MARK: - Garde « ressemble à une phrase » (apprise du test live 12/06 :
    // le corpus réel contient e-mails, noms de fichiers et markup qui passaient
    // les filtres du bench)

    @Test func emailExclu() {
        let block = StylePrimer.block(
            from: [prose("gabriel.exemple@quelquechose-assez-long.net")],
            activeDomain: .other, tone: .neutral)
        #expect(block.isEmpty)
    }

    @Test func nomDeFichierExclu() {
        // 2 mots < 5 — un nom de fichier n'est pas une phrase.
        let block = StylePrimer.block(
            from: [prose("blockfi transactions-export-complet.numbers")],
            activeDomain: .other, tone: .neutral)
        #expect(block.isEmpty)
    }

    @Test func markupExclu() {
        let block = StylePrimer.block(
            from: [prose("pour le gras j'utilise <strong>mot</strong> et c'est tout")],
            activeDomain: .other, tone: .neutral)
        #expect(block.isEmpty)
    }

    @Test func langueEtrangereExclueQuandFrappeFR() {
        let entries = [
            prose("thank you so much for your prompt response about everything"),
            prose("je vous remercie de votre retour et reste à votre disposition"),
        ]
        let block = StylePrimer.block(from: entries, activeDomain: .other, tone: .neutral, language: "French")
        #expect(block == "je vous remercie de votre retour et reste à votre disposition")
    }

    @Test func langueInconnueNeFiltrePas() {
        let entries = [prose("je vous remercie de votre retour et reste à votre disposition")]
        let block = StylePrimer.block(from: entries, activeDomain: .other, tone: .neutral, language: nil)
        #expect(!block.isEmpty)
    }
}
