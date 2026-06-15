import Foundation

/// Prompts des transformations « // » — mêmes templates (Gemma turns / Qwen ChatML),
/// même placement message-EN-DERNIER (KV-LCP), mêmes garde-fous d'entités dures
/// que `translation`/`reformulation`. ④ ton réutilise `reformulation(of:tone:)`,
/// ⑤ traduire réutilise `translation(of:into:)` — rien à ajouter pour eux.
extension GemmaChatPrompt {

    /// Borne l'instruction libre injectée dans la consigne — au-delà l'utilisateur
    /// ne donne plus une consigne, il colle un texte ; on tronque pour garder le
    /// préfixe stable court (KV-LCP) et limiter les dérives du modèle.
    static let maxFreeInstructionLength = 200

    /// Balises de chat-template neutralisées dans l'instruction libre : un
    /// utilisateur (ou un texte collé) qui contient `<start_of_turn>` /
    /// `<|im_start|>` ne doit JAMAIS pouvoir ouvrir un tour dans le prompt.
    private static let templateMarkers = [
        "<start_of_turn>", "<end_of_turn>",
        "<|im_start|>", "<|im_end|>", "<|endoftext|>",
    ]

    // MARK: - Prompts publics

    /// ① corriger — orthographe/grammaire/typographie SANS reformuler.
    public static func correction(
        of frenchText: String,
        model: InstructModel = .gemma1b
    ) -> String {
        assemble(instruction: correctionInstruction(), message: frenchText, model: model)
    }

    /// ② raccourcir — même sens, même registre, nettement plus court.
    public static func shortening(
        of frenchText: String,
        model: InstructModel = .gemma1b
    ) -> String {
        assemble(instruction: shorteningInstruction(), message: frenchText, model: model)
    }

    /// ③ reformuler — dis-le autrement, fluidité, sens et registre conservés.
    public static func rephrasing(
        of frenchText: String,
        model: InstructModel = .gemma1b
    ) -> String {
        assemble(instruction: rephrasingInstruction(), message: frenchText, model: model)
    }

    /// Instruction libre tapée après « // » (« rends ça plus poli »…).
    /// L'instruction utilisateur est insérée dans la consigne (assainie : balises
    /// de chat-template neutralisées, longueur bornée), le message reste
    /// EN DERNIER. Les garde-fous (fidélité, entités, réponse seule) ENCADRENT
    /// l'instruction libre pour limiter les dérives du modèle.
    public static func freeTransformation(
        of frenchText: String,
        instruction: String,
        model: InstructModel = .gemma1b
    ) -> String {
        assemble(
            instruction: freeInstruction(sanitizedInstruction(instruction)),
            message: frenchText,
            model: model)
    }

    /// Rédaction (« // » en début de champ) — développe une amorce (mots-clés /
    /// notes tapés après « // ») en un texte complet. Pas de texte source : c'est
    /// l'amorce elle-même qui occupe la place du « message » (EN DERNIER, KV-LCP).
    /// L'amorce est assainie (balises de chat-template neutralisées) — elle vient
    /// de la frappe utilisateur, jamais elle ne doit ouvrir un tour.
    /// `language` = nom de langue (en français, sans article : « français »,
    /// « anglais »…) résolu par l'appelant depuis la préférence `ComposeLanguage` ;
    /// défaut « français » (comportement d'origine).
    public static func composition(
        from seed: String,
        language: String = "français",
        model: InstructModel = .gemma1b
    ) -> String {
        assemble(
            instruction: compositionInstruction(language: language),
            message: sanitizedInstruction(seed),
            model: model)
    }

    // MARK: - Assemblage

    /// Assemble consigne + message selon le chat-template — factorisation du
    /// switch dupliqué dans `translation`/`reformulation` (ne les modifie pas).
    static func assemble(instruction: String, message: String, model: InstructModel) -> String {
        switch model {
        case .gemma1b:
            // Gemma-3 : pas de rôle système séparé → consigne + message dans le
            // tour user, message EN DERNIER (réutilisation KV-cache LCP).
            return userOpen + instruction + "\n\nMessage : \(message)" + turnClose + modelOpen
        case .qwen1_5b:
            // Qwen2.5 : ChatML, consigne en SYSTÈME (préfixe stable → KV-LCP),
            // message en user.
            return "<|im_start|>system\n" + instruction + "<|im_end|>\n"
                + "<|im_start|>user\n" + message + "<|im_end|>\n"
                + "<|im_start|>assistant\n"
        }
    }

    /// Assainit l'instruction libre : retire TOUTES les balises de chat-template
    /// (en boucle — leur retrait peut en recomposer une, ex. `<<|im_start|>|im_start|>`),
    /// trim, puis tronque à `maxFreeInstructionLength`.
    static func sanitizedInstruction(_ raw: String) -> String {
        var s = raw
        var changed = true
        while changed {
            changed = false
            for marker in templateMarkers where s.contains(marker) {
                s = s.replacingOccurrences(of: marker, with: "")
                changed = true
            }
        }
        s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return String(s.prefix(maxFreeInstructionLength))
    }

    // MARK: - Consignes internes

    static func correctionInstruction() -> String {
        """
        Tu es un correcteur professionnel. Corrige UNIQUEMENT l'orthographe, la grammaire, la ponctuation et la typographie du message ci-dessous, EN FRANÇAIS — ne le reformule pas, ne change ni le ton ni la structure, n'y réponds pas.
        Conserve exactement les noms propres, montants, pourcentages, dates, nombres et termes techniques (wallet, Binance, staking, NFT, gas, CSV, PDF, Stripe…).
        Réponds UNIQUEMENT par le texte corrigé, sans commentaire ni guillemets.
        """
    }

    static func shorteningInstruction() -> String {
        """
        Tu es un rédacteur professionnel. Raccourcis nettement le message ci-dessous, EN FRANÇAIS : garde toutes les informations essentielles, le sens et le registre, supprime les redondances et les détours — n'y réponds pas.
        Conserve exactement les noms propres, montants, pourcentages, dates, nombres et termes techniques (wallet, Binance, staking, NFT, gas, CSV, PDF, Stripe…).
        Conserve les sauts de ligne et la structure en paragraphes du message.
        Réponds UNIQUEMENT par la version raccourcie, sans commentaire ni guillemets.
        """
    }

    static func rephrasingInstruction() -> String {
        """
        Tu es un rédacteur professionnel. Reformule le message ci-dessous, EN FRANÇAIS : dis la même chose autrement, avec une formulation plus fluide et naturelle — même sens, même registre, même longueur approximative, n'y réponds pas.
        Conserve exactement les noms propres, montants, pourcentages, dates, nombres et termes techniques (wallet, Binance, staking, NFT, gas, CSV, PDF, Stripe…).
        Conserve les sauts de ligne et la structure en paragraphes du message.
        Réponds UNIQUEMENT par la reformulation, sans commentaire ni guillemets.
        """
    }

    static func compositionInstruction(language: String = "français") -> String {
        // Consigne retenue après comparatif empirique sur le 1B-it (eval jetable,
        // amorces ultra-courtes) : la variante CONCISE « 1ʳᵉ personne + politesses
        // d'usage, aucun fait inventé » sort de vrais messages naturels et garde
        // les noms donnés (« Paul »). Deux écueils écartés à la mesure :
        // - PAS d'exemples de termes techniques (wallet, Stripe…) : la parenthèse
        //   d'exemples de l'ancienne consigne FUITAIT dans la sortie (« Le wallet
        //   sera disponible… » sur une amorce qui n'en parlait pas).
        // - PAS de « formules de politesse / reprends exactement » trop appuyé :
        //   ça basculait vers la lettre administrative (« salutations distinguées »,
        //   placeholder « [Votre Nom] »). Le registre court et direct gagne.
        let L = language.uppercased()
        return """
        À partir de ces quelques mots, écris le message que je veux envoyer, EN \(L) : court, naturel, poli, à la première personne (2 à 4 phrases). Ajoute les politesses d'usage mais aucun fait inventé (noms, dates, montants non donnés).
        Réponds UNIQUEMENT par le message rédigé EN \(L), sans objet, sans en-tête ni guillemets.
        """
    }

    static func freeInstruction(_ userInstruction: String) -> String {
        """
        Tu es un rédacteur professionnel. Réécris le message ci-dessous EN FRANÇAIS en appliquant fidèlement cette consigne : « \(userInstruction) ». Ne réponds pas au message, n'ajoute rien qui ne découle pas de la consigne.
        Conserve exactement les noms propres, montants, pourcentages, dates, nombres et termes techniques (wallet, Binance, staking, NFT, gas, CSV, PDF, Stripe…).
        Sauf si la consigne demande de restructurer, conserve les sauts de ligne et la structure en paragraphes du message.
        Réponds UNIQUEMENT par la réécriture, sans commentaire ni guillemets.
        """
    }
}
