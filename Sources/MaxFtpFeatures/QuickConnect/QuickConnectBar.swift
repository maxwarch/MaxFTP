import MaxFtpCore
import SwiftUI

/// Barre « Connexion rapide » de la barre d'outils.
struct QuickConnectBar: View {
    let resolver: () -> QuickConnectResolver
    let onConnect: (ConnectionConfiguration) -> Void

    @State private var address = ""
    @State private var password = ""
    @State private var isInvalid = false

    var body: some View {
        HStack(spacing: 6) {
            Menu {
                let aliases = resolver().sshAliases
                if aliases.isEmpty {
                    Text("Aucun hôte dans ~/.ssh/config")
                }
                ForEach(aliases, id: \.self) { alias in
                    Button(alias) { address = "sftp://\(alias)" }
                }
            } label: {
                Image(systemName: "bolt.horizontal")
            }
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Hôtes de ~/.ssh/config")

            TextField("sftp://utilisateur@hôte:port/chemin", text: $address)
                .frame(minWidth: 220, idealWidth: 300)
                .onSubmit(connect)
                .onChange(of: address) { isInvalid = false }
                .overlay(alignment: .trailing) {
                    if isInvalid {
                        Image(systemName: "exclamationmark.circle.fill")
                            .foregroundStyle(.red)
                            .padding(.trailing, 6)
                            .help("Adresse invalide")
                    }
                }

            SecureField("Mot de passe", text: $password)
                .frame(width: 120)
                .onSubmit(connect)

            Button("Connexion", action: connect)
                .disabled(address.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .textFieldStyle(.roundedBorder)
    }

    private func connect() {
        guard let configuration = resolver().configuration(for: address, password: password) else {
            isInvalid = true
            return
        }
        password = ""
        onConnect(configuration)
    }
}

/// Version repliée de la barre, quand une session occupe la fenêtre.
struct QuickConnectButton: View {
    let resolver: () -> QuickConnectResolver
    let onConnect: (ConnectionConfiguration) -> Void

    @State private var isPresented = false

    var body: some View {
        Button {
            isPresented.toggle()
        } label: {
            Label("Connexion rapide", systemImage: "bolt.horizontal")
        }
        .help("Connexion rapide")
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            QuickConnectBar(resolver: resolver) { configuration in
                isPresented = false
                onConnect(configuration)
            }
            .padding()
        }
    }
}

/// Feuille « Connexion rapide », ouverte depuis l'écran « Non connecté » : la barre
/// de la barre d'outils peut être repliée dans le menu » quand la fenêtre est étroite.
struct QuickConnectSheet: View {
    let resolver: () -> QuickConnectResolver
    let onConnect: (ConnectionConfiguration) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Connexion rapide")
                .font(.headline)
            QuickConnectBar(resolver: resolver, onConnect: onConnect)
            Text("Exemple : sftp://utilisateur@hôte:22/var/www. Le bouton ⚡ liste les hôtes de ~/.ssh/config.")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Annuler") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(width: 660)
    }
}
