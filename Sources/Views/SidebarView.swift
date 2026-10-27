import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: Sidebar: search + tree
struct SidebarView: View {
    @EnvironmentObject var store: Store
    @FocusState private var focused: Bool
    @FocusState private var listFocused: Bool
    var body: some View {
        let rows = store.rows()
        let flat = rows.map(\.node)
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField(store.searchContent ? LocalizedStringKey("Search names, URLs, headers, bodies") : LocalizedStringKey("Search by name"), text: $store.query).textFieldStyle(.plain).focused($focused)
                    .onSubmit { store.jump(1); focused = true }          // Enter → next match
                if !store.query.isEmpty {
                    Text(store.counter).font(.caption.monospacedDigit()).foregroundStyle(store.matches.isEmpty ? Color.red : Color.secondary)
                    Button { store.jump(-1) } label: { Image(systemName: "chevron.up") }.buttonStyle(.borderless).disabled(store.matches.isEmpty)
                    Button { store.jump(1) } label: { Image(systemName: "chevron.down") }.buttonStyle(.borderless).disabled(store.matches.isEmpty)
                    Button { store.query = "" } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.borderless).foregroundStyle(.secondary)
                }
            }
            .padding(6).background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.12))).padding([.horizontal, .top], 8)
            HStack {
                Toggle("By content", isOn: $store.searchContent).toggleStyle(.checkbox).controlSize(.small).font(.caption)
                Spacer()
            }.padding(.horizontal, 10).padding(.top, 4).padding(.bottom, 6)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(rows, id: \.node.id) { r in NodeRow(node: r.node, depth: r.depth, flat: flat).id(r.node.id) }
                    }
                }
                .onChange(of: store.scrollTick) {
                    if let id = store.scrollID { DispatchQueue.main.async { withAnimation { proxy.scrollTo(id) } } }
                }
                .focusable()
                .focused($listFocused)
                .focusEffectDisabled()
                .simultaneousGesture(TapGesture().onEnded { listFocused = true })
                .onMoveCommand { dir in
                    let extend = NSEvent.modifierFlags.contains(.shift)
                    switch dir {
                    case .up: store.moveSelection(-1, extend: extend, rows: flat)
                    case .down: store.moveSelection(1, extend: extend, rows: flat)
                    case .left: store.collapseOrParent(rows: flat)
                    case .right: store.expandPrimary()
                    @unknown default: break
                    }
                }
                .onDeleteCommand { store.deleteSelected() }
                .onCopyCommand { store.copySelected(cut: false); return [NSItemProvider(object: (store.primary?.name ?? "") as NSString)] }
                .onCutCommand { store.copySelected(cut: true); return [NSItemProvider(object: (store.primary?.name ?? "") as NSString)] }
                .onPasteCommand(of: [.text]) { _ in store.paste() }
                .onKeyPress(phases: [.down]) { press in
                    if press.key == .return { if let n = store.primary { if n.children != nil { store.toggle(n) } else { store.tab = .request } }; return .handled }
                    if press.characters.lowercased() == "a", press.modifiers.contains(.command) { store.selected = Set(flat); return .handled }
                    return .ignored
                }
            }
            if rows.isEmpty { Placeholder(store.query.isEmpty ? "⌘O — import a collection" : "Nothing found") }
            Divider()
            HStack(spacing: 14) {
                Button { store.add(folder: false) } label: { Label("New Request", systemImage: "plus").lineLimit(1) }.buttonStyle(.borderless)
                Menu {
                    Button("Postman collection…") { store.importCollections() }
                    Button("cURL command…") { store.showCurlImport = true }
                } label: { Label("Import", systemImage: "square.and.arrow.down").lineLimit(1) }
                    .menuStyle(.borderlessButton).fixedSize()
                SettingsLink { Label("Settings", systemImage: "gearshape").labelStyle(.iconOnly) }.buttonStyle(.borderless).help("Settings")
                Spacer()
            }.padding(8)
        }
        .onChange(of: store.focusSearch) { focused = true }
        .sheet(isPresented: $store.showCurlImport) { CurlImportSheet().environmentObject(store) }
    }
}

struct NodeRow: View {
    @EnvironmentObject var store: Store
    @ObservedObject var node: Node
    let depth: Int
    let flat: [Node]
    var body: some View {
        let sel = store.selected.contains(node)
        let hit = store.matchIDs.contains(node.id)
        HStack(spacing: 6) {
            Color.clear.frame(width: CGFloat(depth) * 14, height: 1)
            if node.children != nil {
                Button { store.toggle(node) } label: { Image(systemName: store.isOpen(node) ? "chevron.down" : "chevron.right").font(.caption2).frame(width: 12) }.buttonStyle(.borderless)
                Image(systemName: node.isRoot ? "shippingbox" : "folder").foregroundStyle(sel ? .white : .secondary)
            } else {
                Color.clear.frame(width: 12)
                Text(node.method).font(.system(size: 10, weight: .bold, design: .monospaced)).foregroundStyle(sel ? .white : color(node.method)).frame(width: 40, alignment: .leading)
            }
            Text(highlighted(node.name, store.queryTrimmed)).lineLimit(1).foregroundStyle(sel ? .white : .primary)
            if store.unsavedIDs.contains(node.id) { Circle().fill(sel ? Color.white : Color.orange).frame(width: 7, height: 7).help("Unsaved") }
            Spacer()
            if !node.folderHeaders.isEmpty { Image(systemName: "text.badge.plus").font(.caption2).foregroundStyle(sel ? .white : .secondary) }
        }
        .padding(.vertical, 4).padding(.horizontal, 8)
        .background(sel ? Color.accentColor : (hit ? Color.yellow.opacity(0.22) : Color.clear))
        .contentShape(Rectangle())
        .onTapGesture { store.click(node, rows: flat) }
        .overlay(alignment: .top) { if store.dropHint == DropHint(id: node.id, pos: .before) { Rectangle().fill(Color.accentColor).frame(height: 2) } }
        .overlay(alignment: .bottom) { if store.dropHint == DropHint(id: node.id, pos: .after) { Rectangle().fill(Color.accentColor).frame(height: 2) } }
        .overlay { if store.dropHint == DropHint(id: node.id, pos: .inside) { RoundedRectangle(cornerRadius: 4).stroke(Color.accentColor, lineWidth: 2) } }
        .onDrag { store.beginDrag(node); return NSItemProvider(object: node.id.uuidString as NSString) }
        .onDrop(of: [.text], delegate: NodeDropDelegate(node: node, store: store))
        .contextMenu {
            Button("Run") { store.select(node); store.run() }
            Button("New Request") { store.select(node); store.add(folder: false) }      // on a request: created in the same folder
            if node.children != nil { Button("New Folder") { store.select(node); store.add(folder: true) } }
            Button("Rename…") { store.select(node); store.rename() }
            if !node.isRoot { Button("Copy") { store.select(node); store.copySelected(cut: false) }; Button("Cut") { store.select(node); store.copySelected(cut: true) } }
            if !store.clipboard.isEmpty { Button("Paste") { store.select(node); store.paste() } }
            Button("Duplicate") { store.select(node); store.duplicate() }
            if node.isRoot { Button("Export as Postman Collection…") { store.select(node); store.exportSelected() } }
            Divider()
            Button("Delete", role: .destructive) { store.select(node); store.deleteSelected() }
        }
    }
    func highlighted(_ s: String, _ q: String) -> AttributedString {
        var a = AttributedString(s)
        for v in Node.layoutVariants(q) where !v.isEmpty {      // also highlights the other-layout spelling
            if let r = a.range(of: v, options: .caseInsensitive) { a[r].backgroundColor = .yellow; a[r].foregroundColor = .black; break }
        }
        return a
    }
    func color(_ m: String) -> Color {
        switch m { case "GET": .green; case "POST": .orange; case "PUT": .blue; case "DELETE": .red; case "PATCH": .purple; default: .gray }
    }
}

/// Drop on a row: upper part = before, lower part = after, middle of a folder = inside it.
struct NodeDropDelegate: DropDelegate {
    let node: Node
    let store: Store
    private func position(_ y: CGFloat) -> DropPos {
        let h: CGFloat = 26
        if node.children != nil { return y < h * 0.25 ? .before : (y > h * 0.75 ? .after : .inside) }
        return y < h / 2 ? .before : .after
    }
    func validateDrop(info: DropInfo) -> Bool { !store.dragging.isEmpty }
    func dropUpdated(info: DropInfo) -> DropProposal? {
        let hint = DropHint(id: node.id, pos: position(info.location.y))
        if store.dropHint != hint { store.dropHint = hint }
        return DropProposal(operation: .move)
    }
    func dropExited(info: DropInfo) { if store.dropHint?.id == node.id { store.dropHint = nil } }
    func performDrop(info: DropInfo) -> Bool { store.drop(onto: node, pos: position(info.location.y)); return true }
}

// MARK: Import a request from a pasted curl command
struct CurlImportSheet: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var error = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Paste a cURL command, for example from “Copy as cURL” in the browser (bash or cmd).").font(.callout)
            CodeEditor(text: $text, syntax: .curl, autofocus: true).frame(minHeight: 220)
            if !error.isEmpty { Text(error).font(.caption).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Import") {
                    if let e = store.importCurl(text) { error = e } else { dismiss() }
                }.keyboardShortcut(.defaultAction).disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(16).frame(width: 620)
        .onAppear {
            if let s = NSPasteboard.general.string(forType: .string), s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().hasPrefix("curl") { text = s }
        }
    }
}
