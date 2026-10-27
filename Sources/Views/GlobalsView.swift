import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: Globals
struct GlobalsView: View {
    @EnvironmentObject var store: Store
    var body: some View {
        VStack(alignment: .leading) {
            HStack { Text("Globals").font(.title3.bold()); Spacer(); Button("Add") { store.globals.append(Var()) } }
            List {
                ForEach($store.globals) { $v in GlobalRow(v: $v) }
            }
        }.padding()
    }
}

/// One variable. The lock to the right of the value hides it (the value is then stored encrypted, see SecretVault.swift);
/// the eye shows it again, which always asks for Touch ID / the login password.
private struct GlobalRow: View {
    @EnvironmentObject var store: Store
    @Binding var v: Var
    @State private var shown: String?          // plain text of a revealed secret; nil = hidden
    @State private var original = ""
    @State private var busy = false
    @State private var hideTask: Task<Void, Never>?

    var body: some View {
        HStack {
            Toggle("", isOn: $v.enabled).labelsHidden()
            TextField("Variable", text: $v.key).frame(width: 220)
            valueField
            if v.secret {
                Button { toggleReveal() } label: { Image(systemName: shown == nil ? "eye" : "eye.slash") }
                    .buttonStyle(.borderless).disabled(busy)
                    .help(LocalizedStringKey(shown == nil ? "Show value" : "Hide value"))
            }
            Button { toggleSecret() } label: { Image(systemName: v.secret ? "lock.fill" : "lock.open") }
                .buttonStyle(.borderless).disabled(busy)
                .foregroundStyle(v.secret ? Color.accentColor : Color.secondary)
                .help(LocalizedStringKey(v.secret ? "Secret variable: click to make it a normal variable" : "Hide value (store encrypted)"))
            Button { hideNow(); store.globals.removeAll { $0.id == v.id } } label: { Image(systemName: "trash") }.buttonStyle(.borderless)
        }
        .onDisappear { hideNow() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in hideNow() }
        .onChange(of: shown) { if shown != nil { scheduleHide() } }
    }

    @ViewBuilder private var valueField: some View {
        if !v.secret {
            TextField("Value", text: $v.value)
        } else if shown != nil {
            TextField("Value", text: Binding(get: { shown ?? "" }, set: { shown = $0 }))
        } else {
            HStack(spacing: 6) {
                Text(v.value.isEmpty ? "" : "••••••••••").foregroundStyle(.secondary)
                Spacer(minLength: 0)
                if !v.value.isEmpty && !SecretBox.isSealed(v.value) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        .help(LocalizedStringKey("Not encrypted yet. It will be encrypted at the next unlock."))
                }
            }
            .padding(.horizontal, 7).frame(maxWidth: .infinity, minHeight: 22, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 5).fill(Color.secondary.opacity(0.12)))
        }
    }

    // MARK: Actions
    private func toggleSecret() {
        let id = v.id, wasSecret = v.secret
        busy = true
        Task { @MainActor in
            defer { busy = false }
            do {
                if wasSecret { shown = nil; try await store.makePlain(id) } else { try await store.makeSecret(id) }
            } catch { store.vaultError(error) }
        }
    }

    private func toggleReveal() {
        if shown != nil { hideNow(); return }
        let id = v.id
        busy = true
        Task { @MainActor in
            defer { busy = false }
            do {
                let plain = try await store.revealSecret(id)       // asks for Touch ID / password every time
                original = plain; shown = plain
            } catch { store.vaultError(error) }
        }
    }

    /// Hide the value again; a changed value is encrypted and stored.
    private func hideNow() {
        hideTask?.cancel(); hideTask = nil
        guard let text = shown else { return }
        shown = nil
        let changed = text != original, id = v.id
        original = ""
        if changed {
            Task { @MainActor in
                do { try await store.updateSecret(id, plain: text) } catch { store.vaultError(error) }
            }
        }
    }

    /// A revealed value hides itself 30 s after the last keystroke.
    private func scheduleHide() {
        hideTask?.cancel()
        hideTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(30))
            if !Task.isCancelled { hideNow() }
        }
    }
}
