import MaxFtpCore
import SwiftUI

extension View {
    /// Branche toutes les feuilles et confirmations de l'explorateur sur ``BrowserModel``.
    func browserPrompts(model: BrowserModel) -> some View {
        modifier(BrowserPromptsModifier(model: model))
    }
}

private struct BrowserPromptsModifier: ViewModifier {
    @Bindable var model: BrowserModel

    func body(content: Content) -> some View {
        content
            .sheet(item: $model.prompt) { prompt in
                switch prompt {
                case .newFolder:
                    NameInputSheet(title: "Nouveau dossier", initialName: "Nouveau dossier", actionTitle: "Créer") { name in
                        Task { await model.createFolder(named: name) }
                    }
                case .rename(let item):
                    NameInputSheet(title: "Renommer « \(item.name) »", initialName: item.name, actionTitle: "Renommer") { name in
                        Task { await model.rename(item, to: name) }
                    }
                case .permissions(let item):
                    PermissionsEditorView(item: item) { permissions in
                        Task { await model.setPermissions(permissions, for: item) }
                    }
                }
            }
            .confirmationDialog(
                deletionTitle,
                isPresented: Binding(
                    get: { !model.pendingDeletion.isEmpty },
                    set: { if !$0 { model.pendingDeletion = [] } }
                ),
                titleVisibility: .visible
            ) {
                Button("Supprimer", role: .destructive) {
                    // Capturé tout de suite : la fermeture du dialogue vide `pendingDeletion`.
                    let targets = model.pendingDeletion
                    Task { await model.delete(targets) }
                }
            } message: {
                Text("Cette action est irréversible. Le contenu des dossiers sera supprimé.")
            }
            .alert(
                "Erreur",
                isPresented: Binding(
                    get: { model.errorMessage != nil },
                    set: { if !$0 { model.errorMessage = nil } }
                ),
                presenting: model.errorMessage
            ) { _ in
                Button("OK") {}
            } message: { message in
                Text(message)
            }
    }

    private var deletionTitle: String {
        let items = model.pendingDeletion
        return items.count == 1 ? "Supprimer « \(items[0].name) » ?" : "Supprimer \(items.count) éléments ?"
    }
}

/// Saisie d'un nom (nouveau dossier, renommage).
struct NameInputSheet: View {
    @Environment(\.dismiss) private var dismiss
    let title: String
    let actionTitle: String
    let onCommit: (String) -> Void
    @State private var name: String

    init(title: String, initialName: String, actionTitle: String, onCommit: @escaping (String) -> Void) {
        self.title = title
        self.actionTitle = actionTitle
        self.onCommit = onCommit
        _name = State(initialValue: initialName)
    }

    private var isValid: Bool {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        return !trimmed.isEmpty && !trimmed.contains("/")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.headline)
            TextField("Nom", text: $name)
                .textFieldStyle(.roundedBorder)
                .onSubmit(commit)
            HStack {
                Spacer()
                Button("Annuler", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(actionTitle, action: commit)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!isValid)
            }
        }
        .padding()
        .frame(width: 360)
    }

    private func commit() {
        guard isValid else { return }
        onCommit(name)
        dismiss()
    }
}

/// Éditeur CHMOD : cases à cocher synchronisées avec la valeur octale.
struct PermissionsEditorView: View {
    @Environment(\.dismiss) private var dismiss
    let item: RemoteItem
    let onCommit: (POSIXPermissions) -> Void
    @State private var permissions: POSIXPermissions
    @State private var octalText: String

    init(item: RemoteItem, onCommit: @escaping (POSIXPermissions) -> Void) {
        self.item = item
        self.onCommit = onCommit
        let initial = item.permissions ?? POSIXPermissions(rawValue: item.isDirectory ? 0o755 : 0o644)
        _permissions = State(initialValue: initial)
        _octalText = State(initialValue: initial.octalString)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Permissions de « \(item.name) »").font(.headline)

            Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 8) {
                GridRow {
                    Text("")
                    ForEach(POSIXPermissions.Access.allCases, id: \.self) { Text($0.label).font(.caption).foregroundStyle(.secondary) }
                }
                ForEach(POSIXPermissions.Scope.allCases, id: \.self) { scope in
                    GridRow {
                        Text(scope.label)
                        ForEach(POSIXPermissions.Access.allCases, id: \.self) { access in
                            Toggle("", isOn: binding(access, scope))
                                .labelsHidden()
                                .toggleStyle(.checkbox)
                                .gridColumnAlignment(.center)
                        }
                    }
                }
            }

            HStack {
                TextField("Octal", text: $octalText)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                    .frame(width: 70)
                    .onChange(of: octalText) {
                        if let parsed = POSIXPermissions(octal: octalText) { permissions = parsed }
                    }
                Text(permissions.symbolicString)
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(.secondary)
            }

            HStack {
                Spacer()
                Button("Annuler", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Appliquer") {
                    onCommit(permissions)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding()
        .frame(width: 380)
    }

    private func binding(_ access: POSIXPermissions.Access, _ scope: POSIXPermissions.Scope) -> Binding<Bool> {
        Binding(
            get: { permissions.allows(access, for: scope) },
            set: {
                permissions.set(access, for: scope, enabled: $0)
                octalText = permissions.octalString
            }
        )
    }
}
