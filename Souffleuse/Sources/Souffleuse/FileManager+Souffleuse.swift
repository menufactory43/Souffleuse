import Foundation

extension FileManager {
    /// `~/Library/Application Support/Souffleuse/<subpath>`, créé si besoin.
    ///
    /// Centralise la résolution du dossier de support, jusque-là dupliquée dans six
    /// stores avec un `urls(for:in:)[0]` non gardé — qui *crashait* sur tableau vide
    /// (config système inhabituelle, sandbox dégradé). On replie ici sur
    /// `~/Library/Application Support` dérivé de `NSHomeDirectory()` : le chemin
    /// effectif reste identique dans le cas normal, sans le force-index dangereux.
    static func souffleuseSupportDirectory(subpath: String = "") -> URL {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
                .appendingPathComponent("Library/Application Support", isDirectory: true)
        var dir = base.appendingPathComponent("Souffleuse", isDirectory: true)
        if !subpath.isEmpty {
            dir = dir.appendingPathComponent(subpath, isDirectory: true)
        }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}
