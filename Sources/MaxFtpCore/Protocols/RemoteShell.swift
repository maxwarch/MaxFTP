import Foundation

/// Shell interactif sur le serveur (pseudo-terminal SSH).
///
/// Indépendant de l'émulateur qui l'affiche : celui-ci envoie les frappes avec
/// ``send(_:)`` et affiche les octets du flux renvoyé par ``start(columns:rows:)``.
public protocol RemoteShell: Actor {
    /// Ouvre la session ; le flux se termine quand le shell se ferme (`exit`).
    func start(columns: Int, rows: Int) async throws -> AsyncThrowingStream<Data, any Error>
    func send(_ data: Data) async
    func resize(columns: Int, rows: Int) async
    func close() async
}

/// Fabrique de shells : `nil` si le protocole n'en offre pas (FTP, S3).
public protocol RemoteShellFactory: Sendable {
    func makeShell(for configuration: ConnectionConfiguration) -> (any RemoteShell)?
}

/// Lignes de commande shell construites à partir du domaine. Logique pure.
public enum ShellCommand {
    /// Citation POSIX : `'…'`, avec `'` remplacé par `'\''`.
    public static func quote(_ argument: String) -> String {
        "'" + argument.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
    }

    /// Tapé dans le shell à l'ouverture : l'espace initial l'exclut de l'historique
    /// (bash `ignorespace`, zsh `HIST_IGNORE_SPACE`), `clear` masque la commande.
    public static func changeDirectory(to path: RemotePath) -> String {
        " cd -- \(quote(path.string)) && clear\n"
    }

    /// Commande `ssh` interactive qui ouvre un shell de connexion dans `path`
    /// (pour un terminal externe : Terminal.app, iTerm…).
    public static func interactiveSSH(_ configuration: ConnectionConfiguration, at path: RemotePath?) -> [String] {
        var arguments = ["ssh", "-t"]
        if configuration.port != ConnectionProtocol.sftp.defaultPort {
            arguments += ["-p", String(configuration.port)]
        }
        if case .privateKey(let key, _) = configuration.credential {
            arguments += ["-i", key.path]
        }
        let user = configuration.username
        arguments.append(user.isEmpty ? configuration.host : "\(user)@\(configuration.host)")
        if let path {
            // Le dossier est cité pour le shell distant ; `exec $SHELL -l` garde un shell de connexion.
            arguments.append("cd -- \(quote(path.string)) && exec \"$SHELL\" -l")
        }
        return arguments
    }

    /// Script `.command` (ouvert par Terminal.app) lançant ``interactiveSSH(_:at:)`` ;
    /// il s'efface dès son lancement (il ne contient aucun secret, mais rien ne sert de le garder).
    public static func terminalScript(_ configuration: ConnectionConfiguration, at path: RemotePath?) -> String {
        let command = interactiveSSH(configuration, at: path).map(quote).joined(separator: " ")
        return "#!/bin/sh\nrm -f -- \"$0\"\nclear\nexec \(command)\n"
    }
}
