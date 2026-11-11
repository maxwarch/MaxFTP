import MaxFtpCore
import SwiftUI

/// Feuille de création / modification d'un favori.
struct BookmarkEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var bookmark: ServerBookmark
    @State private var secret: String
    private let onSave: (ServerBookmark, String) -> Void

    init(draft: BookmarkDraft, onSave: @escaping (ServerBookmark, String) -> Void) {
        _bookmark = State(initialValue: draft.bookmark)
        _secret = State(initialValue: draft.secret)
        self.onSave = onSave
    }

    private var isS3: Bool { bookmark.connectionProtocol.isObjectStorage }

    private var usesKey: Bool {
        bookmark.connectionProtocol.supportsKeyAuthentication && bookmark.authenticationKind == .privateKey
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    TextField("Nom", text: $bookmark.name, prompt: Text(bookmark.host.isEmpty ? "Mon serveur" : bookmark.host))
                    Picker("Protocole", selection: $bookmark.connectionProtocol) {
                        ForEach(ConnectionProtocol.allCases) { Text($0.displayName).tag($0) }
                    }
                    .onChange(of: bookmark.connectionProtocol) { old, new in
                        if bookmark.port == old.defaultPort { bookmark.port = new.defaultPort }
                    }
                    if isS3 {
                        TextField("Point de terminaison", text: $bookmark.host,
                                  prompt: Text("<id-compte>.r2.cloudflarestorage.com"))
                        TextField("Région", text: $bookmark.s3Region, prompt: Text("auto"))
                        TextField("Access Key ID", text: $bookmark.username)
                    } else {
                        TextField("Hôte", text: $bookmark.host, prompt: Text("ftp.exemple.fr"))
                        TextField("Port", value: $bookmark.port, format: .number.grouping(.never))
                        TextField("Utilisateur", text: $bookmark.username)
                    }
                }

                Section("Authentification") {
                    if bookmark.connectionProtocol.supportsKeyAuthentication {
                        Picker("Méthode", selection: $bookmark.authenticationKind) {
                            ForEach(ServerBookmark.AuthenticationKind.allCases) { Text($0.displayName).tag($0) }
                        }
                        .pickerStyle(.segmented)
                    }
                    if usesKey {
                        LabeledContent("Clé privée") {
                            HStack {
                                Text(bookmark.privateKeyPath ?? "~/.ssh/id_ed25519")
                                    .foregroundStyle(bookmark.privateKeyPath == nil ? .secondary : .primary)
                                    .truncationMode(.middle)
                                    .lineLimit(1)
                                Button("Choisir…") {
                                    if let url = LocalWorkspace.choosePrivateKey(startingAt: bookmark.privateKeyPath) {
                                        bookmark.privateKeyPath = (url.path as NSString).abbreviatingWithTildeInPath
                                    }
                                }
                            }
                        }
                        SecureField("Passphrase", text: $secret, prompt: Text("Aucune"))
                    } else if isS3 {
                        SecureField("Secret Access Key", text: $secret)
                        Text("Cloudflare R2 : tableau de bord › R2 › Gérer les jetons d'API R2. "
                            + "La région est « auto ». Si le jeton est limité à un bucket, "
                            + "indiquez-le comme dossier initial (/nom-du-bucket).")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        SecureField("Mot de passe", text: $secret)
                    }
                    Text("Les secrets sont enregistrés dans le trousseau macOS.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Options") {
                    TextField("Dossier initial", text: Binding(
                        get: { bookmark.initialPath ?? "" },
                        set: { bookmark.initialPath = $0.isEmpty ? nil : $0 }
                    ), prompt: Text(isS3 ? "/nom-du-bucket (sinon liste des buckets)" : "Dossier de connexion"))
                    if bookmark.connectionProtocol.isFTPFamily {
                        Picker("Mode de transfert", selection: $bookmark.ftpDataMode) {
                            ForEach(FTPDataConnectionMode.allCases) { Text($0.displayName).tag($0) }
                        }
                    }
                    if bookmark.connectionProtocol.usesTLS {
                        Toggle("Accepter les certificats non vérifiés", isOn: $bookmark.allowsUntrustedCertificates)
                    }
                }
            }
            .formStyle(.grouped)

            HStack {
                Spacer()
                Button("Annuler", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Enregistrer") {
                    onSave(bookmark, secret)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(bookmark.host.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding()
        }
        .frame(width: 460)
    }
}
