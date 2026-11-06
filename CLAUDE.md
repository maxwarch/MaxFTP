# MaxFtp — consignes pour les agents

Client FTP/FTPS/SFTP natif macOS. Lire ARCHITECTURE.md avant de modifier le code.

## Commandes
- Build : `swift build` — Tests : `swift test` — App : `make app` (→ `build/MaxFtp.app`)
- Tests d'intégration (opt-in) : `Scripts/test-ftp-server.py`, `Scripts/test-sshd.sh`
- Icône : `swift Scripts/make-icon.swift` (source `Resources/Icon/AppIcon-source.jpg` → `Resources/AppIcon.icns`)

## Règles
- `MaxFtpCore` n'importe rien hors Foundation/CryptoKit. `MaxFtpFeatures` n'importe que Core.
  Les implémentations concrètes ne se câblent que dans `MaxFtpApp/AppComposition.swift`.
- Swift 6 strict : modèles UI `@MainActor @Observable`, connexions = `actor`.
  Dans `FTPFileSystem`, toute opération publique passe par `exclusive { }` ; ne jamais
  appeler une méthode publique depuis un `exclusive`.
- Toute nouvelle logique : fonction pure ou derrière un protocole, avec un test
  (doublures dans `MaxFtpTestSupport`).
- Nouveau champ de `ServerBookmark` : `decodeIfPresent` + valeur par défaut.
- Pas de macros nécessitant Xcode (`@Entry`, `#Preview`) : le projet doit compiler avec
  les seuls Command Line Tools.
- UI et messages d'erreur en français ; commentaires en français.
- Décision structurante → nouvelle ADR dans `docs/adr/`.
