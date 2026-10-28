import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: Main layout
struct ContentView: View {
    @EnvironmentObject var store: Store
    @Environment(\.openSettings) private var openSettings
    var body: some View {
        NavigationSplitView {
            SidebarView().navigationSplitViewColumnWidth(min: 250, ideal: 300)
        } detail: {
            VStack(spacing: 0) {
                HStack { TabStrip(items: MainTab.allCases.map { ($0, L($0.rawValue)) }, selection: $store.tab)
                    if !store.storageProblems.isEmpty {
                        HStack(spacing: 8) {
                            Image(systemName: "exclamationmark.triangle.fill")
                            Text(store.storageProblems.joined(separator: " · ")).lineLimit(1).truncationMode(.middle)
                            Button(L("Check paths in Settings")) { openSettings() }.controlSize(.small)
                        }
                        .font(.caption).foregroundStyle(.white)
                        .padding(.horizontal, 10).padding(.vertical, 4)
                        .background(Color.red, in: RoundedRectangle(cornerRadius: 8))
                        .layoutPriority(1)
                    }
                    Spacer(minLength: 0) }.padding(8)
                Divider()
                switch store.tab {
                case .request:
                    if store.selected.count == 1, let n = store.primary {
                        if n.children == nil { RequestEditor(node: n).id(n.id) } else { FolderEditor(node: n).id(n.id) }
                    } else if !store.selected.isEmpty { BulkEditor() }
                    else { Placeholder("Select a request or folder") }
                case .runner: RunnerView()
                case .globals: GlobalsView()
                case .log: LogTabView(logs: store.logStore)
                }
            }
        }
        .alert("Error", isPresented: Binding(get: { store.error != nil }, set: { _ in store.error = nil })) { Button("OK") {} } message: { Text(store.error ?? "") }
    }
}

struct Placeholder: View {
    let t: String; init(_ t: String) { self.t = t }
    var body: some View { Text(LocalizedStringKey(t)).foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity) }
}
