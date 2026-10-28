import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: Folder / collection editor
struct FolderEditor: View {
    @EnvironmentObject var store: Store
    @ObservedObject var node: Node
    @State private var mode = 0
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                TextField("Name", text: $node.name).textFieldStyle(.plain).font(.title3.bold())
                Spacer()
                Button("Run") { store.run() }.buttonStyle(.borderedProminent)
            }
            Picker("", selection: $mode) { Text("Headers").tag(0); Text("Bulk edit").tag(1) }.pickerStyle(.segmented).labelsHidden().frame(width: 360)
            if mode == 0 {
                Text("Applied automatically to every nested request and shown there as read-only. A request's own header with the same name overrides it. When exporting, they are written into each request.")
                    .font(.caption).foregroundStyle(.secondary)
                HeadersEditor(items: $node.folderHeaders)
            } else { BulkEditor(embedded: true) }
        }.padding()
    }
}
