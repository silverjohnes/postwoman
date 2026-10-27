import SwiftUI

/// Window ▸ Keyboard Shortcuts (also opened from Settings).
struct ShortcutsView: View {
    private struct Row: Identifiable { let id = UUID(); let keys: String; let what: String }
    private let rows: [Row] = [
        Row(keys: "⌘↩", what: "Send Request"), Row(keys: "⌘R", what: "Run Selected"), Row(keys: "⌘.", what: "Stop"), Row(keys: "⌥⌘P", what: "Pause"),
        Row(keys: "⌘N", what: "New Request"), Row(keys: "⇧⌘N", what: "New Folder"),
        Row(keys: "⌘O", what: "Import Collection…"), Row(keys: "⇧⌘I", what: "Import cURL…"), Row(keys: "⇧⌘E", what: "Export Collection…"),
        Row(keys: "⌘S", what: "Save"), Row(keys: "⌥⌘S", what: "Save All"),
        Row(keys: "⌘Z", what: "Undo"), Row(keys: "⇧⌘Z", what: "Redo"),
        Row(keys: "⌘E", what: "Rename"), Row(keys: "⌘D", what: "Duplicate"), Row(keys: "⌫  ⌘⌫", what: "Delete Selected Items"),
        Row(keys: "⌘C  ⌘X  ⌘V", what: "Copy, cut and paste items in the list (a curl command is imported as a request)"),
        Row(keys: "⌘A", what: "Select all"), Row(keys: "↑ ↓ ← →", what: "Move through the list (⇧ extends the selection)"),
        Row(keys: "⇧-click  ⌘-click", what: "Select several: ⇧-click selects a range, ⌘-click adds or removes"),
        Row(keys: "⌫  ⌘⌫", what: "Delete the selected executions in History"),
        Row(keys: "⌘F", what: "Find"), Row(keys: "⇧⌘F", what: "Search Collections"), Row(keys: "⌘G", what: "Next Match"), Row(keys: "⇧⌘G", what: "Previous Match"),
        Row(keys: "⌘1", what: "Request"), Row(keys: "⌘2", what: "Runner"), Row(keys: "⌘3", what: "Globals"), Row(keys: "⌘4", what: "Log"),
    ]
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(rows) { r in
                    HStack(alignment: .firstTextBaseline, spacing: 16) {
                        Text(r.keys).font(.system(.body, design: .monospaced).bold()).frame(width: 150, alignment: .leading)
                        Text(LocalizedStringKey(r.what)).frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(.vertical, 5)
                    Divider()
                }
            }
            .padding(16)
        }
        .frame(width: 640, height: 560)
    }
}
