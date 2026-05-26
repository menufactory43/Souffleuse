import Foundation
import SouffleuseLlama

let modelPath = NSString(string: "~/Library/Application Support/app.cotypist.Cotypist/Models/gemma-3-1b.i1-Q5_K_M.gguf").expandingTildeInPath

let engine = LlamaEngine()

let ok = await engine.load(modelPath: modelPath, contextTokens: 2048)
guard ok else {
    FileHandle.standardError.write("LOAD FAILED\n".data(using: .utf8)!)
    exit(1)
}
FileHandle.standardError.write("LOADED\n".data(using: .utf8)!)

let pre = "Bonjour, je voulais vous écrire pour vous"
let after = ""
let instr = "Tu es un moteur d'autocomplétion. Continue le texte EXACTEMENT là où il s'arrête, dans la même langue. Réponds UNIQUEMENT par la suite du texte (quelques mots), sans répéter ce qui précède, sans guillemets, sans explication."
let prompt = "<start_of_turn>user\n\(instr)\n\nTexte avant le curseur :\n\(pre)" + (after.isEmpty ? "" : "\n\nTexte après le curseur :\n\(after)") + "<end_of_turn>\n<start_of_turn>model\n\(pre)"

final class Sink: @unchecked Sendable { var s = "" }
let sink = Sink()
let metrics = await engine.generate(prompt: prompt, maxTokens: 24) { tok in
    sink.s += tok
    return true
}
let out = sink.s
FileHandle.standardError.write("TTFT=\(metrics.ttftMillis ?? -1)ms tps=\(metrics.tokensPerSecond ?? -1)\n".data(using: .utf8)!)
print("PROMPT_PRE: \(pre)")
print("COMPLETION: \(out)")
