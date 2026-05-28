import Foundation

/// Strips known-noisy patterns from OCR-extracted visible text before it
/// reaches the LLM prompt. Targets the meta-events and UI chrome that
/// Intercom-style support tools sprinkle through the conversation pane —
/// "Attribution : Workflow", "Vous avez mis la conversation en pause", "Fin a
/// automatiquement repris la conversation", etc. These take chars from the
/// 240-char visible budget without giving the model any usable signal.
///
/// **Conservative + bounded by design.** Patterns are precise multi-token
/// strings that would rarely occur verbatim in a customer message. Where a
/// match could otherwise eat customer text downstream (e.g., "Vous avez mis
/// la conversation en pause jusqu'à 30 mai, 10:04 Merci pour l'astuce"), the
/// trailing capture is *length-bounded* (max ~25 chars of date) rather than
/// `.*` greedy, so customer prose after the metadata stays untouched.
///
/// Order matters: earlier patterns get first dibs on overlapping matches.
/// Most-specific is listed first to avoid a broad pattern eating a fragment
/// the narrower one would have caught cleanly.
public enum VisibleTextCleaner {
    public static func clean(_ text: String) -> String {
        var result = text
        for pattern in patterns {
            let range = NSRange(result.startIndex..., in: result)
            result = pattern.stringByReplacingMatches(
                in: result, options: [], range: range, withTemplate: " "
            )
        }
        // Collapse whitespace runs that cleanup leaves behind.
        result = result.replacingOccurrences(
            of: "\\s{2,}", with: " ", options: .regularExpression
        )
        // Trim leading symbol-only residue ("• * - " after stripping).
        result = result.replacingOccurrences(
            of: "^[•·*\\-_=\\s]+", with: "", options: .regularExpression
        )
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static let patterns: [NSRegularExpression] = {
        let raw = [
            // Workflow-attribution header.
            // Vision OCR often mangles `»` into `>`, so the closing class is
            // `[»>]`. The opening "« Assignment Rules ..." span is bounded
            // to ≤ 100 chars to avoid runaway matches if `»` is missing.
            #"[•·]?\s*Attribution\s*:\s*Workflow\s*:\s*«[^»>]{0,100}[»>]?"#,
            // Attribution clause "a attribué à <Name> [et <Team>]" — typically
            // appears right after the workflow header but can stand alone.
            // Bounded to a capitalised name + optional team token so customer
            // prose like "Tu m'as mis en relation" isn't swallowed.
            #"\s*a\s+attribué\s+(?:à\s+)?[A-Z][\w\-]+(?:\s+et\s+[\w\-]+)*"#,
            // Standalone "Attribution : <Name> [et <Team>] [(par défaut)]"
            // form (no Workflow prefix). Same name-shape bounding.
            #"[•·]?\s*Attribution\s*:\s*[A-Z][\w\-]+(?:\s+et\s+[\w\-]+)*(?:\s*\(par\s+défaut\))?"#,
            // Intercom AI agent ("Fin") automated events — exact verb phrases
            // (no `.*` greedy tails, the verb itself terminates).
            #"\bFin\s+a\s+suivi\s+les\s+conseils\s+ci-dessous"#,
            #"\bFin\s+a\s+automatiquement\s+repris\s+la\s+conversation"#,
            #"\bFin\s+a\s+réactivé\s+automatiquement\s+le\s+ticket"#,
            // Conversation/ticket pause + resume events. Date suffix is
            // bounded to ≤ 25 chars so the regex stops well before any
            // customer text that follows.
            #"[&€(]?\s*Vous\s+avez\s+mis\s+la\s+conversation\s+en\s+pause(?:\s+jusqu'à\s+[\d\sa-zéàèïçô,:\-]{1,25})?"#,
            #"[&€(]?\s*Vous\s+avez\s+repris\s+la\s+conversation"#,
            #"[&€(]?\s*Vous\s+avez\s+mis\s+le\s+ticket\s+en\s+pause(?:\s+jusqu'à\s+[\d\sa-zéàèïçô,:\-]{1,25})?"#,
            // Consultation timer
            #"\bConsultation\s*[•·]?\s*\d+\s*(?:min|h)\b"#,
            // Close button label
            #"[&€]\s*Fermer\b"#,
            // Defensive: stray "« Assignment Rules … »" bracket if the
            // surrounding Attribution match somehow didn't catch it.
            #"«\s*Assignment\s+Rules[^»>]{0,80}[»>]?"#,
            // Fin guardrails right-pane chip
            #"\bWarnings\s+Utilisez\s+un\s+langage\s+simple\b"#,
        ]
        // Case-SENSITIVE on purpose. All Intercom UI labels are deterministic
        // ("Attribution", "Workflow", "Vous avez", "Fin", "Consultation",
        // "Fermer", "Warnings") so a flag bringing zero value would break the
        // bounded character classes ("[a-z]" should NOT match capitals like
        // "Merci" in customer text following a pause-event date).
        return raw.compactMap {
            try? NSRegularExpression(pattern: $0, options: [])
        }
    }()
}
