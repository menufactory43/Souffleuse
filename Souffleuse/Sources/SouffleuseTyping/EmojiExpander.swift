import Foundation

public struct EmojiExpansion: Sendable, Equatable {
    /// How many characters before the caret to delete (the `:shortcode: ` block).
    public let deleteChars: Int
    /// The replacement (emoji + the trailing trigger char, e.g. `"😄 "`).
    public let insert: String
    /// Lowercase shortcode without colons, for telemetry.
    public let shortcode: String

    public init(deleteChars: Int, insert: String, shortcode: String) {
        self.deleteChars = deleteChars
        self.insert = insert
        self.shortcode = shortcode
    }
}

/// Curated ~150 GitHub-flavored shortcodes. Kept inline (not a resource bundle)
/// because the table is tiny and avoids resource lookup at startup. Extend by
/// adding entries here; user-defined extensions can come in a later phase.
public enum EmojiTable {
    public static let map: [String: String] = [
        // Smiley faces
        "smile": "😄", "smiley": "😃", "grin": "😁", "laughing": "😆", "rofl": "🤣",
        "joy": "😂", "blush": "😊", "innocent": "😇", "wink": "😉",
        "yum": "😋", "sunglasses": "😎", "heart_eyes": "😍", "kissing_heart": "😘",
        "thinking": "🤔", "raised_eyebrow": "🤨", "neutral_face": "😐", "expressionless": "😑",
        "no_mouth": "😶", "smirk": "😏", "unamused": "😒", "rolling_eyes": "🙄",
        "grimacing": "😬", "lying_face": "🤥", "relieved": "😌", "pensive": "😔",
        "sleepy": "😪", "drooling_face": "🤤", "sleeping": "😴", "mask": "😷",
        "face_with_thermometer": "🤒", "nauseated_face": "🤢", "sneezing_face": "🤧",
        "hot_face": "🥵", "cold_face": "🥶", "dizzy_face": "😵",
        "exploding_head": "🤯", "cowboy_hat_face": "🤠", "partying_face": "🥳",
        "sunglasses_face": "😎", "nerd_face": "🤓",
        "confused": "😕", "worried": "😟", "frowning": "😦", "anguished": "😧",
        "open_mouth": "😮", "astonished": "😲", "flushed": "😳", "pleading_face": "🥺",
        "cry": "😢", "sob": "😭", "scream": "😱", "fearful": "😨",
        "cold_sweat": "😰", "disappointed": "😞", "tired_face": "😩", "weary": "😩",
        "triumph": "😤", "rage": "😡", "angry": "😠",

        // Hand gestures
        "wave": "👋", "raised_back_of_hand": "🤚", "raised_hand": "✋",
        "vulcan_salute": "🖖", "ok_hand": "👌", "pinched_fingers": "🤌",
        "victory_hand": "✌️", "crossed_fingers": "🤞", "love_you_gesture": "🤟",
        "metal": "🤘", "call_me_hand": "🤙", "point_left": "👈", "point_right": "👉",
        "point_up_2": "👆", "middle_finger": "🖕", "point_down": "👇",
        "thumbsup": "👍", "thumbsdown": "👎", "fist": "✊", "punch": "👊",
        "raised_fist": "✊", "clap": "👏", "raised_hands": "🙌", "open_hands": "👐",
        "palms_up_together": "🤲", "handshake": "🤝", "pray": "🙏",

        // Heart / love
        "heart": "❤️", "orange_heart": "🧡", "yellow_heart": "💛", "green_heart": "💚",
        "blue_heart": "💙", "purple_heart": "💜", "black_heart": "🖤", "white_heart": "🤍",
        "broken_heart": "💔", "two_hearts": "💕", "sparkling_heart": "💖",
        "heartpulse": "💗", "cupid": "💘", "gift_heart": "💝",

        // Symbols
        "fire": "🔥", "star": "⭐", "star2": "🌟", "sparkles": "✨",
        "boom": "💥", "collision": "💥", "zap": "⚡", "rainbow": "🌈",
        "sun": "☀️", "cloud": "☁️", "umbrella": "☔", "snowflake": "❄️",
        "snowman": "⛄", "comet": "☄️",

        // Tech
        "computer": "💻", "iphone": "📱", "keyboard": "⌨️", "desktop_computer": "🖥️",
        "printer": "🖨️", "mouse_three_button": "🖱️", "joystick": "🕹️",
        "floppy_disk": "💾", "cd": "💿", "dvd": "📀", "battery": "🔋",
        "plug": "🔌", "bulb": "💡", "satellite": "🛰️",

        // Common reactions / objects
        "rocket": "🚀", "tada": "🎉", "confetti_ball": "🎊", "balloon": "🎈",
        "checkered_flag": "🏁", "trophy": "🏆", "medal_sports": "🏅", "first_place_medal": "🥇",
        "warning": "⚠️", "no_entry": "⛔", "x": "❌", "white_check_mark": "✅",
        "heavy_check_mark": "✔️", "ballot_box_with_check": "☑️", "question": "❓",
        "exclamation": "❗", "bangbang": "‼️", "interrobang": "⁉️",
        "100": "💯", "muscle": "💪", "ok": "🆗", "new": "🆕",
        "cool": "🆒", "free": "🆓", "soon": "🔜", "top": "🔝",

        // Food / drink
        "coffee": "☕", "tea": "🍵", "beer": "🍺", "wine_glass": "🍷",
        "champagne": "🍾", "cocktail": "🍸", "tropical_drink": "🍹",
        "pizza": "🍕", "hamburger": "🍔", "fries": "🍟", "hotdog": "🌭",
        "taco": "🌮", "burrito": "🌯", "salad": "🥗", "popcorn": "🍿",
        "doughnut": "🍩", "cookie": "🍪", "birthday": "🎂", "cake": "🍰",
        "chocolate_bar": "🍫", "candy": "🍬", "lollipop": "🍭",

        // Animals (small selection)
        "dog": "🐶", "cat": "🐱", "mouse": "🐭", "rabbit": "🐰", "fox": "🦊",
        "bear": "🐻", "panda_face": "🐼", "koala": "🐨", "tiger": "🐯", "lion": "🦁",
        "cow": "🐮", "pig": "🐷", "frog": "🐸", "monkey_face": "🐵",
        "owl": "🦉", "eagle": "🦅", "snake": "🐍", "dragon": "🐉",
        "unicorn": "🦄",
    ]
}

/// Un candidat du picker — la paire shortcode/emoji affichée avec un badge ①–⑨.
public struct EmojiCandidate: Sendable, Equatable {
    public let shortcode: String
    public let emoji: String

    public init(shortcode: String, emoji: String) {
        self.shortcode = shortcode
        self.emoji = emoji
    }
}

/// État du picker pour un `:fragment` ouvert avant le caret. `fragmentLength`
/// compte le `:` D'OUVERTURE + le fragment tapé — c'est exactement ce qu'il faut
/// supprimer (`replaceTrailing`) quand l'utilisateur choisit un candidat.
public struct EmojiPickerState: Sendable, Equatable {
    /// Caractères avant le caret à remplacer à la sélection (`:sm` → 3).
    public let fragmentLength: Int
    /// Au plus 9 candidats ; la position visuelle (badge ①–⑨) = index + 1.
    public let candidates: [EmojiCandidate]

    public init(fragmentLength: Int, candidates: [EmojiCandidate]) {
        self.fragmentLength = fragmentLength
        self.candidates = candidates
    }
}

public enum EmojiExpander {
    /// Detect a completed `:shortcode:<space|newline>` at the end of the text
    /// before the caret. Returns nil if no completion is present, the shortcode
    /// is unknown, or the user is mid-typing the shortcode.
    public static func detect(textBeforeCaret: String) -> EmojiExpansion? {
        // Need at least `:x: ` (4 chars) to even be a candidate.
        guard textBeforeCaret.count >= 4 else { return nil }
        let trigger = textBeforeCaret.last!
        guard trigger == " " || trigger == "\n" || trigger == "\t" else { return nil }
        // Strip the trailing trigger and find the preceding `:code:` block.
        let withoutTrigger = textBeforeCaret.dropLast()
        guard withoutTrigger.hasSuffix(":") else { return nil }
        let body = withoutTrigger.dropLast()  // drop closing colon
        // Find the opening colon — must be on the same line and contain only [a-zA-Z0-9_+-].
        var i = body.endIndex
        var code = ""
        while i > body.startIndex {
            let prev = body.index(before: i)
            let c = body[prev]
            if c == ":" {
                // Found opening colon; capture and stop.
                if code.isEmpty { return nil }
                let trailing = String(trigger)
                guard let emoji = EmojiTable.map[code.lowercased()] else { return nil }
                let deleteChars = code.count + 2 + 1  // :code: + trigger
                return EmojiExpansion(
                    deleteChars: deleteChars,
                    insert: emoji + trailing,
                    shortcode: code.lowercased()
                )
            }
            if !isShortcodeChar(c) { return nil }
            code = String(c) + code
            i = prev
        }
        return nil
    }

    private static func isShortcodeChar(_ c: Character) -> Bool {
        c.isLetter || c.isNumber || c == "_" || c == "+" || c == "-"
    }

    // MARK: - Picker interactif (parité Cotypist)

    /// Sélection curée pour l'état « : » nu d'un utilisateur sans historique —
    /// les réactions universelles, dans l'esprit de la rangée par défaut de
    /// Cotypist (👋 🙂 😀 ☀️ 😊 …). Dès que la fréquence d'usage existe, elle
    /// prime ; cette liste ne sert que de complément.
    public static let curatedPopular: [String] = [
        "wave", "blush", "smile", "joy", "heart",
        "thumbsup", "tada", "fire", "pray",
    ]

    /// État du picker pour le `:fragment` ouvert juste avant le caret, ou nil si
    /// aucun picker ne doit s'afficher. Pur et synchrone — toute la politique de
    /// déclenchement (gardes 14:30 / std:: / http:) vit ici pour être testable.
    ///
    /// Règles :
    /// - le `:` d'ouverture doit être précédé de RIEN (début de texte) ou d'un
    ///   caractère qui n'est ni lettre, ni chiffre, ni `:`. Ça neutralise les
    ///   heures (« 14: »), les ports d'URL, les schémas (« http: ») et les
    ///   namespaces C++ (« std:: ») sans liste d'exceptions.
    /// - fragment vide (« : » nu) → top `limit` par fréquence d'usage, complété
    ///   par `curatedPopular`.
    /// - fragment non vide → prefix-match sur les shortcodes, trié fréquence
    ///   décroissante puis alphabétique. Aucun match → nil (le panneau se ferme).
    public static func pickerCandidates(
        textBeforeCaret: String,
        limit: Int = 9,
        frequency: [String: Int] = [:]
    ) -> EmojiPickerState? {
        guard limit > 0 else { return nil }
        // Remonte depuis le caret en n'acceptant que des chars de shortcode,
        // jusqu'au `:` d'ouverture. Tout autre char (espace, ponctuation…)
        // signifie qu'aucun fragment n'est ouvert.
        var i = textBeforeCaret.endIndex
        var fragment = ""
        var opener: String.Index?
        while i > textBeforeCaret.startIndex {
            let prev = textBeforeCaret.index(before: i)
            let c = textBeforeCaret[prev]
            if c == ":" { opener = prev; break }
            guard isShortcodeChar(c) else { return nil }
            fragment = String(c) + fragment
            i = prev
        }
        guard let opener else { return nil }
        // Garde du caractère AVANT le `:` (cf. doc ci-dessus).
        if opener > textBeforeCaret.startIndex {
            let before = textBeforeCaret[textBeforeCaret.index(before: opener)]
            if before.isLetter || before.isNumber || before == ":" { return nil }
        }

        let lower = fragment.lowercased()
        let matches: [String]
        if lower.isEmpty {
            // « : » nu — l'usage personnel d'abord, le curé en complément.
            let used = EmojiTable.map.keys
                .filter { frequency[$0, default: 0] > 0 }
                .sorted {
                    let (fa, fb) = (frequency[$0]!, frequency[$1]!)
                    return fa != fb ? fa > fb : $0 < $1
                }
            var seen = Set(used)
            matches = used + curatedPopular.filter { seen.insert($0).inserted }
        } else {
            matches = EmojiTable.map.keys
                .filter { $0.hasPrefix(lower) }
                .sorted {
                    let (fa, fb) = (frequency[$0, default: 0], frequency[$1, default: 0])
                    return fa != fb ? fa > fb : $0 < $1
                }
        }
        let candidates = matches.prefix(limit).compactMap { code in
            EmojiTable.map[code].map { EmojiCandidate(shortcode: code, emoji: $0) }
        }
        guard !candidates.isEmpty else { return nil }
        return EmojiPickerState(fragmentLength: 1 + fragment.count, candidates: candidates)
    }

    /// Apps where shortcode expansion would clash with intended syntax
    /// (`std::vector`, `::` namespace ops, `:emoji_alias:` in source code).
    public static let disabledBundles: Set<String> = [
        "com.microsoft.VSCode",
        "com.microsoft.VSCodeInsiders",
        "com.visualstudio.code.oss",
        "com.apple.dt.Xcode",
        "com.googlecode.iterm2",
        "com.apple.Terminal",
        "org.alacritty",
        "com.mitchellh.ghostty",
        "net.kovidgoyal.kitty",
        "dev.zed.Zed",
        "com.jetbrains.intellij",
        "com.jetbrains.pycharm",
        "com.jetbrains.WebStorm",
        "com.jetbrains.goland",
        "com.jetbrains.rider",
        "com.jetbrains.AppCode",
        "com.jetbrains.CLion",
        "com.jetbrains.PhpStorm",
        "com.jetbrains.RubyMine",
        "com.jetbrains.datagrip",
        "com.sublimetext.4",
        "com.sublimetext.3",
    ]
}
