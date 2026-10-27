import Foundation

/// Text for the interface. The key is the English text itself; every language has its own
/// `Resources/Localization/<lang>.lproj/Localizable.strings`. A missing key (or language) falls back to the English key.
/// SwiftUI literals (`Text("Run")`, `Button("Save")`…) are looked up in the same files automatically;
/// `L(...)` is for strings built in code (ternaries, concatenation, alerts, panels). Placeholders: %@ for text, %ld for Int.
func L(_ key: String, _ args: CVarArg...) -> String {
    let f = NSLocalizedString(key, bundle: .main, comment: "")
    return args.isEmpty ? f : String(format: f, arguments: args)
}
