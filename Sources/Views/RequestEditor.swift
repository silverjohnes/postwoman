import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: Single request editor
struct RequestEditor: View {
    @EnvironmentObject var store: Store
    @ObservedObject var node: Node
    @State private var sub: Int         // 0 Params, 1 Headers, 2 Body, 3 Scripts, 4 History
    @State private var scriptSub: Int   // 0 PreScript, 1 PostScript
    init(node: Node) {
        _node = ObservedObject(wrappedValue: node)
        _sub = State(initialValue: node.uiTab); _scriptSub = State(initialValue: node.uiScriptTab)      // come back to the tab that was open
    }
    @AppStorage("showCurlPanel") private var showCurl = false

    static let bodyModes: [(String, String)] = [("none", "none"), ("formdata", "form-data"), ("urlencoded", "x-www-form-urlencoded"), ("raw", "raw"), ("binary", "binary")]

    private var tabs: [(Int, String)] {
        [(0, L("Params") + (node.params.isEmpty ? "" : " (\(node.params.filter(\.enabled).count))")),
         (1, L("Headers") + (node.headers.isEmpty ? "" : " (\(node.headers.count))")),
         (2, L("Body") + (node.bodyMode == "none" ? "" : " •")),
         (3, L("Scripts") + (node.preScript.isEmpty && node.testScript.isEmpty ? "" : " •")),
         (4, L("History"))]
    }

    var body: some View {
        HStack(spacing: 0) {
            editor
            if showCurl {
                Divider()
                CurlPanel(node: node) { showCurl = false }.frame(width: 380)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .clipped()
        .onChange(of: sub) { node.uiTab = sub }
        .onChange(of: scriptSub) { node.uiScriptTab = scriptSub }
        .onChange(of: store.authAlert) { if store.authAlert == node.id { sub = 1 } }
        .onAppear { if node.uiFocusURL { DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { node.uiFocusURL = false } } }
        .onAppear { if node.uiRefocus { DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { node.uiRefocus = false } } }
    }

    private var editor: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                TextField("Name", text: $node.name).textFieldStyle(.plain).font(.title3.bold())
                Button { showCurl.toggle() } label: { Text("</>").font(.system(.body, design: .monospaced).bold()) }
                    .help("curl").buttonStyle(.bordered).tint(showCurl ? Color.accentColor : Color.secondary)
            }
            HStack {
                Picker("", selection: $node.method) { ForEach(["GET", "POST", "PUT", "PATCH", "DELETE", "HEAD", "OPTIONS"], id: \.self) { Text($0) } }.frame(width: 110).labelsHidden()
                VarField(text: $node.url, placeholder: L("URL"), mono: true, autofocus: node.uiFocusURL).frame(maxWidth: .infinity).frame(height: 24)
                Button("Run") { store.run() }.buttonStyle(.borderedProminent)
            }
            HStack {
                TabStrip(items: tabs, selection: $sub)
                Spacer(minLength: 0)
                Text("Autosave on").font(.caption).foregroundStyle(.secondary).lineLimit(1).fixedSize()
            }
            switch sub {
            case 0: paramsTab
            case 1: headersTab
            case 2: bodyTab
            case 3: scriptsTab
            default: HistoryTab(history: store.history, node: node)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .clipped()
    }

    // MARK: Headers
    private var headersTab: some View {
        VStack(alignment: .leading, spacing: 6) {
            let inh = store.inherited(for: node)
            if !inh.isEmpty {
                GroupBox("Inherited from folders (read-only)") {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(inh) { i in
                            let over = node.headers.contains { $0.key.caseInsensitiveCompare(i.h.key) == .orderedSame }
                            HStack(spacing: 8) {
                                Image(systemName: "lock.fill").font(.caption)
                                Text(i.h.key).font(.system(.body, design: .monospaced)).frame(width: 180, alignment: .leading)
                                Text(i.h.value).font(.system(.body, design: .monospaced)).strikethrough(over).lineLimit(1)
                                Spacer()
                                Text(L("from %@", "\(i.from)") + (over ? L(" · overridden below") : "")).font(.caption)
                            }.foregroundStyle(.secondary)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            AuthBanner(node: node)
            HeadersEditor(items: $node.headers, auto: node.autoHeaders(effective: Node.merge(inh.map(\.h), node.headers)),
                          removed: node.disabledAuto.sorted(),
                          onRemoveAuto: { node.disabledAuto.insert($0.lowercased()) }, onRestoreAuto: { node.disabledAuto.remove($0.lowercased()) })
        }
    }

    // MARK: Body
    private var bodyModeItems: [(String, String)] {
        var m = Self.bodyModes
        if !m.contains(where: { $0.0 == node.bodyMode }) { m.append((node.bodyMode, node.bodyMode)) }
        return m
    }
    private var bodyTab: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                TabStrip(items: bodyModeItems, selection: $node.bodyMode)
                if node.bodyMode == "raw" {
                    Picker("", selection: $node.rawLang) {
                        Text("Text").tag("text"); Text("JSON").tag("json"); Text("JavaScript").tag("javascript"); Text("HTML").tag("html"); Text("XML").tag("xml")
                    }.frame(width: 130).labelsHidden()
                    if node.rawLang == "json" {
                        JSONStatus(text: node.body)
                        Button("Beautify") { beautify() }.disabled(node.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
                Spacer(minLength: 0)
            }
            switch node.bodyMode {
            case "none": Placeholder("This request does not have a body")
            case "formdata": FormEditor(rows: $node.formData)
            case "urlencoded": HeadersEditor(items: $node.urlencoded, addTitle: "Add field")
            case "raw": CodeEditor(text: $node.body, syntax: node.rawLang == "json" ? .json : node.rawLang == "javascript" ? .javascript : .plain, autofocus: node.uiRefocus)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            case "binary": binaryPane
            default: Placeholder("This body type is kept as imported and cannot be edited here")
            }
        }
    }
    private var binaryPane: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "doc")
                Text(node.binaryPath.isEmpty ? L("No file selected") : (node.binaryPath as NSString).lastPathComponent)
                    .font(.system(.body, design: .monospaced)).lineLimit(1).truncationMode(.middle)
                Button("Select file…") { if let p = Attachments.pick() { node.binaryPath = p } }
                if !node.binaryPath.isEmpty { Button("Remove") { node.binaryPath = "" } }
            }
            Text("The file is sent as the raw body. It is copied into the storage folder (files).").font(.caption).foregroundStyle(.secondary)
            Spacer()
        }
    }

    // MARK: Scripts
    private var scriptsTab: some View {
        VStack(alignment: .leading, spacing: 6) {
            TabStrip(items: [(0, "PreScript" + (node.preScript.isEmpty ? "" : " •")), (1, "PostScript" + (node.testScript.isEmpty ? "" : " •"))], selection: $scriptSub)
            if scriptSub == 0 {
                ScriptPane(text: $node.preScript, title: "PreScript",
                           hint: "JavaScript, runs before the request: pm.request, pm.globals, pm.sendRequest, console.log… (Postman API)", autofocus: node.uiRefocus)
            } else {
                ScriptPane(text: $node.testScript, title: "PostScript",
                           hint: "JavaScript, runs after the response: pm.response, pm.test, pm.globals, pm.visualizer.set(template, data) → Visualize tab of the result", autofocus: node.uiRefocus)
            }
        }
    }

    var paramsTab: some View {
        VStack(alignment: .leading, spacing: 6) {
            HeadersEditor(items: $node.params, addTitle: "Add parameter")
        }
    }
    func beautify() {
        guard let b = JSONFormat.beautify(node.body) else {
            NSSound.beep(); store.log("body", "Beautify failed for \"\(node.name)\": body is not valid JSON", .warn); return
        }
        if b != node.body { node.body = b; store.log("body", "Beautified JSON body of \"\(node.name)\"", .debug) }
    }
}

// MARK: Authorization banner (Headers tab)
struct AuthBanner: View {
    @EnvironmentObject var store: Store
    @ObservedObject var node: Node
    var body: some View {
        let problem = node.authProblem, note = node.authNote
        if problem != nil || note != nil {
            let alert = store.authAlert == node.id
            VStack(alignment: .leading, spacing: 4) {
                if let note { Label(note, systemImage: "lock.shield").font(.caption).foregroundStyle(.secondary) }
                if let problem {
                    HStack(spacing: 8) {
                        Label(problem, systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.red)
                        if alert { Button("Run anyway") { store.authAlert = nil; store.run(force: true) }.controlSize(.small) }
                    }
                }
            }
            .padding(6).frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 6).fill(alert ? Color.red.opacity(0.25) : Color.clear))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(alert ? Color.red : Color.clear, lineWidth: 2))
            .animation(.easeInOut(duration: 0.3), value: alert)
        }
    }
}

// MARK: curl panel
struct CurlPanel: View {
    @EnvironmentObject var store: Store
    @ObservedObject var node: Node
    let close: () -> Void
    @AppStorage("curlSubstitute") private var substitute = true
    private var text: String { node.curl(headers: store.inherited(for: node).map(\.h), vars: substitute ? store.globals : nil) }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("curl").font(.system(.body, design: .monospaced).bold())
                Spacer()
                CopyButton { text }
                Button { close() } label: { Image(systemName: "xmark") }.buttonStyle(.borderless)
            }
            Toggle("Substitute variables", isOn: $substitute).toggleStyle(.checkbox).font(.caption)
            CodeText(text: text, syntax: .curl, size: 12).frame(maxWidth: .infinity, maxHeight: .infinity)
            Text("Select any part of the command to copy only it.").font(.caption).foregroundStyle(.secondary)
        }
        .padding(10)
    }
}

struct JSONStatus: View {
    let text: String
    var body: some View {
        // `//` comments are ignored (never an error); {{variables}} are replaced by a literal so Postman templates still validate
        let stripped = JSONFormat.withoutComments(text)
        let t = stripped.replacingOccurrences(of: "\\{\\{[^}]*\\}\\}", with: "1", options: .regularExpression)
        if stripped.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { EmptyView() }
        else if (try? JSONSerialization.jsonObject(with: Data(t.utf8), options: .fragmentsAllowed)) != nil {
            Label("Valid JSON", systemImage: "checkmark.circle").foregroundStyle(.green).font(.caption)
        } else { Label("Invalid JSON", systemImage: "xmark.circle").foregroundStyle(.red).font(.caption) }
    }
}

struct HeadersEditor: View {
    @Binding var items: [KV]
    var addTitle = "Add header"
    var auto: [KV] = []                       // read-only rows added by the runtime
    var removed: [String] = []                // auto headers the user removed: they are not sent and not listed, only offered for restoring
    var onRemoveAuto: (String) -> Void = { _ in }
    var onRestoreAuto: (String) -> Void = { _ in }
    var body: some View {
        List {
            ForEach($items) { $h in
                HStack {
                    Toggle("", isOn: $h.enabled).labelsHidden()
                    VarField(text: $h.key, placeholder: L("Key")).frame(height: 24); VarField(text: $h.value, placeholder: L("Value")).frame(height: 24)
                    Button { items.removeAll { $0.id == h.id } } label: { Image(systemName: "minus.circle") }.buttonStyle(.borderless)
                }
            }
            Button(LocalizedStringKey(addTitle)) { items.append(KV()) }
            if !auto.isEmpty {
                Section("Auto-generated headers (added by the runtime when the request is sent)") {
                    ForEach(auto) { a in
                        HStack(spacing: 8) {
                            Image(systemName: "lock.fill").font(.caption)
                            Text(a.key).frame(width: 150, alignment: .leading)
                            Text(a.value).lineLimit(1).truncationMode(.middle).textSelection(.enabled).strikethrough(!a.enabled)
                            Spacer(minLength: 0)
                            if a.enabled {
                                Button("Override") { items.append(KV(key: a.key, value: a.value == Node.calculated ? "" : a.value)) }.buttonStyle(.borderless).font(.caption)
                            }
                            if Node.removableAuto.contains(a.key.lowercased()) {
                                Button { onRemoveAuto(a.key) } label: { Image(systemName: "minus.circle") }.buttonStyle(.borderless).help("Do not send this header")
                            } else {
                                Color.clear.frame(width: 16, height: 1)
                            }
                        }
                        .font(.system(.body, design: .monospaced)).foregroundStyle(.secondary)
                    }
                }
            }
            if !removed.isEmpty {
                Menu {
                    ForEach(removed, id: \.self) { k in Button(k) { onRestoreAuto(k) } }
                } label: { Text(L("Send this header again") + " (\(removed.count))…").font(.caption) }
                    .menuStyle(.borderlessButton).fixedSize()
            }
        }
    }
}

// MARK: form-data editor: text fields and files
struct FormEditor: View {
    @Binding var rows: [FormRow]
    var body: some View {
        List {
            ForEach($rows) { $r in
                HStack {
                    Toggle("", isOn: $r.enabled).labelsHidden()
                    VarField(text: $r.key, placeholder: L("Key")).frame(height: 24)
                    Picker("", selection: $r.isFile) { Text("Text").tag(false); Text("File").tag(true) }.labelsHidden().frame(width: 80)
                    if r.isFile {
                        Text(r.src.isEmpty ? L("No file selected") : (r.src as NSString).lastPathComponent)
                            .lineLimit(1).truncationMode(.middle).frame(maxWidth: .infinity, alignment: .leading).foregroundStyle(.secondary)
                        Button("Select file…") { if let p = Attachments.pick() { r.src = p } }
                    } else {
                        VarField(text: $r.value, placeholder: L("Value")).frame(height: 24)
                    }
                    Button { rows.removeAll { $0.id == r.id } } label: { Image(systemName: "minus.circle") }.buttonStyle(.borderless)
                }
            }
            Button("Add field") { rows.append(FormRow()) }
        }
    }
}

/// Files chosen for form-data / binary bodies are copied into `<storage>/files`, so they stay readable between launches (App Sandbox).
enum Attachments {
    static func pick() -> String? {
        let p = NSOpenPanel(); p.canChooseFiles = true; p.canChooseDirectories = false; p.allowsMultipleSelection = false
        guard p.runModal() == .OK, let u = p.url else { return nil }
        let dir = StorageLocation.current.appendingPathComponent("files")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dest = dir.appendingPathComponent(String(UUID().uuidString.prefix(8)).lowercased() + "-" + u.lastPathComponent)
        do { try FileManager.default.copyItem(at: u, to: dest); return dest.path } catch { return u.path }
    }
}
