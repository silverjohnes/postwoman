import AppKit

/// Interface language chosen in Settings. Stored through the standard `AppleLanguages` override, so it is picked up at the next launch
/// (the bundle's localisations are resolved once at start). "auto" removes the override: the system language decides, English if unsupported.
enum AppLanguage {
    static let all: [(code: String, name: String)] = [
        ("ar", "العربية"), ("bn", "বাংলা"), ("de", "Deutsch"), ("en", "English"), ("es", "Español"), ("fa", "فارسی"),
        ("fr", "Français"), ("hi", "हिन्दी"), ("id", "Bahasa Indonesia"), ("it", "Italiano"), ("ja", "日本語"), ("ko", "한국어"),
        ("nl", "Nederlands"), ("pl", "Polski"), ("pt", "Português"), ("ro", "Română"), ("ru", "Русский"), ("sv", "Svenska"),
        ("th", "ไทย"), ("tr", "Türkçe"), ("uk", "Українська"), ("ur", "اردو"), ("vi", "Tiếng Việt"), ("zh-Hans", "简体中文"), ("zh-Hant", "繁體中文")
    ]
    /// What the user had chosen when this launch started: Settings offers a restart when the choice differs.
    static let launchCode: String = UserDefaults.standard.string(forKey: "appLanguage") ?? "auto"

    static func apply(_ code: String) {
        if code == "auto" { UserDefaults.standard.removeObject(forKey: "AppleLanguages") }
        else { UserDefaults.standard.set([code], forKey: "AppleLanguages") }
    }
    static func relaunch() {
        let c = NSWorkspace.OpenConfiguration(); c.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: c) { _, _ in
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }
    static var versionText: String {
        let i = Bundle.main.infoDictionary
        return (i?["CFBundleShortVersionString"] as? String ?? "?") + " (" + (i?["CFBundleVersion"] as? String ?? "?") + ")"
    }
}
