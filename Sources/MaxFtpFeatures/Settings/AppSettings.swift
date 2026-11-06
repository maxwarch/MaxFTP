import Foundation
import SwiftUI

/// Clés `UserDefaults` des préférences, centralisées pour éviter les fautes de frappe.
public enum AppSettings {
    public static let showHiddenFilesKey = "showHiddenFiles"
    public static let maxConcurrentTransfersKey = "maxConcurrentTransfers"
    public static let previewSizeLimitKey = "previewSizeLimitMB"
    public static let editorChoicesKey = "editorChoices"

    public static let defaultMaxConcurrentTransfers = 2
    public static let defaultPreviewSizeLimitMB = 5

    public static var maxConcurrentTransfers: Int {
        let value = UserDefaults.standard.integer(forKey: maxConcurrentTransfersKey)
        return value > 0 ? value : defaultMaxConcurrentTransfers
    }

    /// Bascule la préférence en relisant la valeur ACTUELLE (les commandes de la barre de
    /// menus ne voient pas les changements d'un `@AppStorage` : un `Toggle` y resterait figé).
    public static func toggleShowHiddenFiles(in defaults: UserDefaults = .standard) {
        defaults.set(!defaults.bool(forKey: showHiddenFilesKey), forKey: showHiddenFilesKey)
    }

    public static var editorChoices: EditorChoices {
        get { EditorChoices(data: UserDefaults.standard.data(forKey: editorChoicesKey) ?? Data()) }
        set { UserDefaults.standard.set(newValue.data, forKey: editorChoicesKey) }
    }

    public static var previewSizeLimit: Int64 {
        let value = UserDefaults.standard.integer(forKey: previewSizeLimitKey)
        return Int64(value > 0 ? value : defaultPreviewSizeLimitMB) * 1_000_000
    }
}

/// Fenêtre « Réglages… » (⌘,).
public struct SettingsView: View {
    @AppStorage(AppSettings.showHiddenFilesKey) private var showHiddenFiles = false
    @AppStorage(AppSettings.maxConcurrentTransfersKey) private var maxConcurrentTransfers = AppSettings.defaultMaxConcurrentTransfers
    @AppStorage(AppSettings.previewSizeLimitKey) private var previewSizeLimit = AppSettings.defaultPreviewSizeLimitMB
    @AppStorage(AppSettings.editorChoicesKey) private var editorChoicesData = Data()

    public init() {}

    private var editorChoices: EditorChoices {
        get { EditorChoices(data: editorChoicesData) }
        nonmutating set { editorChoicesData = newValue.data }
    }

    public var body: some View {
        Form {
            Section("Général") {
                Toggle("Afficher les fichiers cachés", isOn: $showHiddenFiles)
                Stepper("Transferts simultanés : \(maxConcurrentTransfers)", value: $maxConcurrentTransfers, in: 1...8)
                Stepper("Aperçu automatique jusqu'à \(previewSizeLimit) Mo", value: $previewSizeLimit, in: 1...100)
            }

            Section {
                LabeledContent("Éditeur par défaut") {
                    HStack(spacing: 8) {
                        ApplicationLabel(url: editorChoices.defaultEditor, placeholder: "Application du système")
                        Button("Choisir…") {
                            if let app = LocalWorkspace.chooseApplication(title: "Choisir l'éditeur par défaut", prompt: "Choisir")?.application {
                                editorChoices.defaultEditor = app
                            }
                        }
                        if editorChoices.defaultEditor != nil {
                            Button("Réinitialiser") { editorChoices.defaultEditor = nil }
                        }
                    }
                }
            } header: {
                Text("Édition")
            } footer: {
                Text("Utilisé par « Éditer » et le double-clic sur un fichier, sauf si une application est associée à son extension.")
                    .foregroundStyle(.secondary)
            }

            if !editorChoices.byExtension.isEmpty {
                Section("Toujours ouvrir avec") {
                    ForEach(editorChoices.byExtension.keys.sorted(), id: \.self) { key in
                        LabeledContent(key.isEmpty ? "Sans extension" : ".\(key)") {
                            HStack(spacing: 8) {
                                ApplicationLabel(url: editorChoices.byExtension[key], placeholder: "")
                                Button {
                                    editorChoices.byExtension[key] = nil
                                } label: {
                                    Image(systemName: "minus.circle.fill")
                                }
                                .buttonStyle(.borderless)
                                .foregroundStyle(.secondary)
                                .help("Ne plus associer .\(key) à cette application")
                                .accessibilityLabel("Supprimer l'association")
                            }
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .fixedSize()
    }
}

/// Icône + nom d'une application (ou texte de remplacement).
private struct ApplicationLabel: View {
    let url: URL?
    let placeholder: String

    var body: some View {
        if let url {
            HStack(spacing: 4) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                    .resizable()
                    .frame(width: 16, height: 16)
                Text(FileManager.default.displayName(atPath: url.path))
                    .foregroundStyle(EditorChoices.applicationExists(url) ? .primary : .secondary)
                    .strikethrough(!EditorChoices.applicationExists(url))
            }
            .help(url.path)
        } else {
            Text(placeholder).foregroundStyle(.secondary)
        }
    }
}
