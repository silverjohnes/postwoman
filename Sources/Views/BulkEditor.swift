import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: Bulk editor (several requests and/or folders selected)
struct BulkEditor: View {
    @EnvironmentObject var store: Store
    var embedded = false
    @State private var headers: [KV] = []
    @State private var remove = ""
    @State private var replaceBody = false
    @State private var body_ = ""
    @State private var json = true
    @State private var setCT = true
    var targets: [Node] { store.requests(in: Array(store.selected)) }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !embedded {
                HStack {
                    if store.selected.count == 1, let n = store.primary { BulkName(node: n) }
                    else { Text(L("%ld items selected", store.selected.count)).font(.title3.bold()) }
                    Spacer()
                    Button("Run") { store.run() }.buttonStyle(.borderedProminent).disabled(store.primary == nil)
                }
            }
            Text(L("Edit %ld request(s) at once. Folders include everything inside.", targets.count)).foregroundStyle(.secondary)
            GroupBox("Set / replace headers") { HeadersEditor(items: $headers).frame(minHeight: 110) }
            TextField("Remove headers (comma-separated names)", text: $remove).textFieldStyle(.roundedBorder)
            Toggle("Replace body", isOn: $replaceBody)
            if replaceBody {
                HStack {
                    Picker("", selection: $json) { Text("Text").tag(false); Text("JSON").tag(true) }.pickerStyle(.segmented).frame(width: 140).labelsHidden()
                    Toggle("Also set Content-Type", isOn: $setCT)
                    if json {
                        JSONStatus(text: body_)
                        Button("Beautify") { if let b = JSONFormat.beautify(body_) { body_ = b } else { NSSound.beep() } }
                            .disabled(body_.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
                TextEditor(text: $body_).font(.system(.body, design: .monospaced)).border(Color.secondary.opacity(0.3))
            } else { Spacer() }
            HStack { Spacer(); Button(L("Apply to %ld request(s)", targets.count)) { apply() }.disabled(targets.isEmpty) }
        }.padding(embedded ? 0 : 16)
    }
    func apply() {
        var set = headers
        if replaceBody && setCT { set.append(KV(key: "Content-Type", value: json ? "application/json" : "text/plain")) }
        store.applyBulk(targets, set: set, remove: remove.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) },
                        body: replaceBody ? body_ : nil, json: json)
        headers = []; remove = ""
    }
}
struct BulkName: View { @ObservedObject var node: Node; var body: some View { TextField("Name", text: $node.name).textFieldStyle(.plain).font(.title3.bold()) } }
