import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: Settings
struct SettingsView: View {
    @EnvironmentObject var store: Store
    @ObservedObject private var vault = SecretVault.shared
    @State private var folderPath = StorageLocation.current.path
    @State private var isDefaultFolder = StorageLocation.isDefault
    @AppStorage("appLanguage") private var appLanguage = "auto"
    @AppStorage("autosave") private var autosave = true
    @Environment(\.openWindow) private var openWindow
    @AppStorage("requestTimeout") private var timeout = 10
    @AppStorage("historyRetentionValue") private var keepValue = 6
    @AppStorage("historyRetentionUnit") private var keepUnit = "months"
    @State private var testing = false
    @State private var testOK = true
    @State private var testSummary = ""

    var body: some View {
        Form {
            Section("Language") {
                LabeledContent("Interface language") {
                    HStack(spacing: 8) {
                        Picker("", selection: $appLanguage) {
                            Text("Automatic (system)").tag("auto")
                            ForEach(AppLanguage.all, id: \.code) { Text($0.name).tag($0.code) }
                        }.labelsHidden().frame(width: 200)
                        if appLanguage != AppLanguage.launchCode { Button("Restart now") { AppLanguage.relaunch() } }
                    }
                }
                note("The language changes after the app is restarted.")
            }

            Section("Saving") {
                Toggle("Autosave", isOn: $autosave)
                note("With autosave on, every change is saved by itself (a request imported from cURL only after you save it with ⌘S). With autosave off, changes are written only by Save (⌘S) or Save All (⌥⌘S); when you quit, every unsaved item is offered for saving.")
                HStack { Spacer(); Button("Keyboard Shortcuts") { openWindow(id: "shortcuts") } }
            }

            Section("Storage") {
                LabeledContent("Folder") {
                    HStack(spacing: 8) {
                        Text(folderPath).font(.system(.body, design: .monospaced)).lineLimit(2).truncationMode(.middle)
                            .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                        Button("Choose…") { chooseFolder() }
                        Button("Default") { resetFolder() }.disabled(isDefaultFolder)
                    }
                }
                note("Collections, globals and history are stored here. The app runs in the macOS sandbox, so it can only use the default folder (inside the app container) or a folder you choose with Choose…. Changing the folder loads the data from the new place. Moving from an older, unsandboxed version: choose its folder (usually ~/Documents/Postwoman).")
            }

            Section("Newman") {
                LabeledContent("Runtime") {
                    Text(runtimeInfo).font(.system(.body, design: .monospaced)).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                note("Newman and Node.js are built into the app: nothing to install and no path to configure.")
                LabeledContent("Check") {
                    HStack(spacing: 8) {
                        if testing { ProgressView().controlSize(.small) }
                        Button(testing ? L("Testing…") : L("Test newman")) { test() }.disabled(testing)
                    }
                }
                if !testSummary.isEmpty {
                    Text(testSummary)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(testOK ? Color.green : Color.red)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)         // wraps instead of being cut off
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            Section("Secret variables") {
                LabeledContent("Key storage") {
                    HStack(spacing: 8) {
                        Text(vaultText).frame(maxWidth: .infinity, alignment: .leading)
                        Button("Lock now") { vault.lock() }.disabled(!vault.unlocked)
                    }
                }
                note("Values marked with the lock are stored AES-256 encrypted. The key lives in this Mac's Keychain, never in the files. Running asks for Touch ID or your password once per launch, showing a value asks every time. Secret values are masked in the Log and in the history. Collections are exported without them.")
            }

            Section("Requests") {
                LabeledContent("Timeout") {
                    HStack(spacing: 6) {
                        TextField("", value: $timeout, format: .number)
                            .textFieldStyle(.roundedBorder).labelsHidden().multilineTextAlignment(.trailing).frame(width: 64)
                        Stepper("", value: $timeout, in: 0...3600).labelsHidden()
                        Text("seconds").foregroundStyle(.secondary)
                    }
                }
                note("0 means no timeout. Applies to every request in the Runner.")
            }

            Section("History") {
                LabeledContent("Keep history for") {
                    HStack(spacing: 6) {
                        TextField("", value: $keepValue, format: .number)
                            .textFieldStyle(.roundedBorder).labelsHidden().multilineTextAlignment(.trailing).frame(width: 64)
                        Stepper("", value: $keepValue, in: 1...(keepUnit == "days" ? 36500 : 1200)).labelsHidden()
                        Picker("", selection: $keepUnit) { Text("months").tag("months"); Text("days").tag("days") }
                            .labelsHidden().frame(width: 100)
                    }
                }
                note("Default: 6 months. Older executions are deleted at startup, after runs and when you close Settings — not while you are typing.")
                HStack { Spacer(); Button("Delete older executions now") { store.pruneHistory(reason: "manual", force: true) } }
            }

            Section("About") {
                LabeledContent("Version") { Text(AppLanguage.versionText).textSelection(.enabled) }
            }
        }
        .formStyle(.grouped)
        .frame(width: 660, height: 800)
        .onChange(of: autosave) { if autosave { store.autosaveTick() }; store.refreshUnsaved(); store.log("settings", "Autosave → \(autosave)") }
        .onChange(of: appLanguage) { AppLanguage.apply(appLanguage); store.log("settings", "Interface language → \(appLanguage) (applied after restart)") }
        .onChange(of: timeout) { store.log("settings", "Request timeout → \(timeout) s") }
        .onChange(of: keepValue) { if keepValue < 1 { keepValue = 1 } }
        .onChange(of: keepUnit) { store.log("settings", "History retention → \(keepValue) \(keepUnit)") }
        .onDisappear { store.pruneHistory(reason: "settings closed") }
    }

    private func note(_ s: String) -> some View {
        Text(LocalizedStringKey(s)).font(.caption).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var vaultText: String {
        guard vault.unlocked else { return L("Locked: asked at the first use after launch") }
        return vault.tier == .login ? L("Login keychain; the app asks for Touch ID or your password before use")
                                    : L("Keychain, protected by Touch ID or your password")
    }

    private var runtimeInfo: String {
        EmbeddedRuntime.problem() == nil ? L("embedded (Contents/Helpers/node + Contents/Resources/newman)") : L("MISSING — rebuild the app")
    }

    private func chooseFolder() {
        let p = NSOpenPanel(); p.canChooseDirectories = true; p.canChooseFiles = false; p.canCreateDirectories = true
        p.prompt = L("Use as storage")
        guard p.runModal() == .OK, let u = p.url else { return }
        if StorageLocation.choose(u) { store.log("settings", "Storage folder → \(u.path) (security-scoped bookmark saved)"); refreshFolder(); store.load() }
        else { store.log("settings", "Could not create a bookmark for \(u.path)", .error) }
    }
    private func resetFolder() {
        StorageLocation.reset(); store.log("settings", "Storage folder → default (\(StorageLocation.defaultFolder.path))"); refreshFolder(); store.load()
    }
    private func refreshFolder() { folderPath = StorageLocation.current.path; isDefaultFolder = StorageLocation.isDefault }

    // MARK: Test newman
    // Runs the embedded node, loads the embedded newman and prints both versions. Hard 20 s timeout; every stage goes to the Log tab (category "newman-test").
    private func test() {
        testing = true; testSummary = ""
        let st = store
        let logf: @Sendable (LogLevel, String) -> Void = { lvl, msg in
            DispatchQueue.main.async { MainActor.assumeIsolated { st.log("newman-test", msg, lvl) } }
        }
        st.log("newman-test", "──── Test embedded newman ────")
        let script = "const p=require('path');const d=process.argv[1];console.log('node '+process.version+' '+process.arch);console.log('newman '+require(p.join(d,'package.json')).version);require(d);console.log('newman library loads: ok')"
        Task {
            let r = await EmbeddedRuntime.run(arguments: ["-e", script, EmbeddedRuntime.newmanDir.path], timeout: 20, log: logf)
            let lines = r.output.split(whereSeparator: \.isNewline).map(String.init).filter { !$0.isEmpty }
            for l in lines { logf(.debug, "output> \(l)") }
            logf(r.status == 0 ? .info : .error, "result: status \(r.status)\(r.timedOut ? ", TIMED OUT" : ""), \(r.elapsedMs) ms")
            if r.timedOut {
                testOK = false; testSummary = L("Timed out after 20 s. The Log tab (category newman-test) has the output so far.")
            } else if let e = r.launchError {
                testOK = false; testSummary = L("Cannot start the embedded node: %@", "\(e)")
            } else if r.status == 0 {
                testOK = true; testSummary = L("OK — %@", lines.prefix(2).joined(separator: ", "))
            } else {
                testOK = false; testSummary = L("Failed (exit %ld): %@\nDetails: Log tab, category newman-test.", Int(r.status), lines.suffix(4).joined(separator: " · "))
            }
            testing = false
        }
    }
}
