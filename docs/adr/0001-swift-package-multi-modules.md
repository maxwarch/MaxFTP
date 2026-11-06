# 0001 — Swift Package multi-modules

**Contexte.** L'app doit rester facile à faire évoluer. Dans un seul target, rien
n'empêche une vue d'importer NIO ou d'appeler le Keychain directement.

**Décision.** Le projet est un Swift Package de 6 modules (Core, FTP, SFTP, Storage,
Features, App). Les frontières sont imposées par le compilateur : `MaxFtpFeatures` ne
peut pas importer `MaxFtpFTP` puisqu'il n'en dépend pas.

**Conséquences.**
- `open Package.swift` ouvre le projet dans Xcode ; `swift build` / `swift test` marchent
  sans Xcode (CI simple).
- Le `.app` est assemblé par `Scripts/build-app.sh` (Info.plist + entitlements + codesign).
  Si un jour il faut des fonctionnalités réservées aux projets Xcode (extensions,
  widgets, App Store), créer un `.xcodeproj` minimal dont la cible app dépend de ce
  package : les modules restent intacts.
- Les macros SwiftUI (`@Entry`, `#Preview`) exigent Xcode : on écrit les clés
  `FocusedValueKey` à la main pour garder la compilation possible en ligne de commande.
