# Architecture de MaxFtp

Client FTP / FTPS / SFTP / S3 (Cloudflare R2) natif macOS (Swift 6, SwiftUI, macOS 14+).
Ce document explique **où mettre quoi** et **pourquoi**. À lire avant toute modification.

## 1. Vue d'ensemble : Ports & Adapters (architecture hexagonale)

```
                  ┌──────────────────────────────────────────┐
                  │ MaxFtpApp — composition root (@main)     │
                  │ Seul endroit qui connaît TOUTES les       │
                  │ implémentations concrètes.                │
                  └───┬───────────┬──────────┬──────────┬────┘
                      │           │          │          │
          ┌───────────▼──┐ ┌──────▼─────┐ ┌──▼───────┐ ┌▼──────────────┐
          │ MaxFtpFeatures│ │ MaxFtpFTP  │ │MaxFtpSFTP│ │ MaxFtpStorage │
          │ SwiftUI + MVVM│ │ SwiftNIO   │ │ Citadel  │ │ Keychain, JSON│
          └───────┬──────┘ └─────┬──────┘ └────┬─────┘ └──────┬────────┘
                  │              │             │              │
                  └──────────────┴──────┬──────┴──────────────┘
                                        ▼
                          ┌──────────────────────────┐
                          │ MaxFtpCore — le domaine  │
                          │ modèles, protocoles,     │
                          │ logique pure. 0 dépendance│
                          └──────────────────────────┘
```

**Règles de dépendance (vérifiées par le compilateur via `Package.swift`) :**

| Module | Peut importer | Ne doit JAMAIS importer |
|---|---|---|
| `MaxFtpCore` | Foundation, CryptoKit | tout le reste |
| `MaxFtpFTP`, `MaxFtpSFTP`, `MaxFtpS3`, `MaxFtpStorage` | Core + leur lib réseau/système | Features, les autres adaptateurs |
| `MaxFtpTerminal` | Core, SwiftTerm, SwiftUI, AppKit | Features, les adaptateurs réseau |
| `MaxFtpFeatures` | Core, SwiftUI, AppKit | FTP, SFTP, Storage, NIO, Citadel |
| `MaxFtpApp` | tout | — |

Conséquence : l'UI ignore totalement si elle parle à un serveur SFTP, FTP, ou à un
faux serveur en mémoire. C'est ce qui rend les modèles de vue testables sans réseau.

## 2. Les contrats (ports) — `Sources/MaxFtpCore/Protocols`

| Protocole | Rôle | Implémentation(s) |
|---|---|---|
| `RemoteFileSystem` (actor) | Opérations sur le serveur | `SFTPFileSystem`, `FTPFileSystem`, `S3FileSystem`, `InMemoryFileSystem` (tests) |
| `RemoteFileSystemFactory` | Choisit l'adaptateur selon le protocole | `ProtocolFileSystemFactory` (App) |
| `BookmarkRepository` | Persistance des favoris | `JSONBookmarkRepository` |
| `PathBookmarkRepository` | Persistance des signets (dossiers / fichiers par serveur) | `JSONPathBookmarkRepository` |
| `SecretStore` | Mots de passe / passphrases / jeton Cloudflare | `KeychainSecretStore` |
| `RemoteShell` (actor) | Shell interactif (pseudo-terminal) | `SSHShell` (SFTP), `FakeShell` (tests) |
| `R2UsageProvider` | Métriques d'un compte Cloudflare R2 | `CloudflareR2Analytics` (S3) |
| `HostKeyStore` | Clés d'hôte SSH approuvées | `JSONHostKeyStore` |
| `HostKeyTrustPolicy` | Faire confiance à une clé SSH ? | `InteractiveHostKeyTrustPolicy` (Features) |

## 3. Patterns utilisés et où les trouver

| Pattern | Où | Pourquoi |
|---|---|---|
| **Strategy / Adapter** | `RemoteFileSystem` + un actor par protocole | Ajouter un protocole sans toucher l'UI |
| **Factory** | `ProtocolFileSystemFactory` | Un `switch` exhaustif : un nouveau `ConnectionProtocol` casse la compilation ici, impossible de l'oublier |
| **Template Method** | extension de `RemoteFileSystem` (`removeItem`, `walk`, `createDirectoryIfNeeded`) | Les adaptateurs n'écrivent que des primitives ; le récursif est écrit une fois |
| **Command** | `TransferPlan.Step` + `TransferExecutor` | Planifier (taille totale connue) puis exécuter ; testable sans réseau |
| **Repository** | `BookmarkRepository` | Passer à SwiftData = une nouvelle classe + une ligne dans `AppComposition` |
| **MVVM** | `BrowserModel`, `BookmarksModel`, `PathBookmarksModel`, `TransferQueue`, `PreviewModel`, `R2DashboardModel` (`@Observable @MainActor`) | Les vues sont déclaratives et sans logique ; la logique est testable |
| **Dependency Injection** | `AppDependencies` (constructeur) + `AppEnvironment` (`.environment`) | Aucun singleton caché ; les tests injectent des doublures |
| **Composition Root** | `MaxFtpApp/AppComposition.swift` | Un seul endroit pour câbler l'app |
| **Actor isolation** | tous les adaptateurs réseau | Swift 6 strict concurrency : pas de data race possible |

## 4. Concurrence

- **Tout ce qui touche l'UI est `@MainActor`** (modèles `@Observable`).
- **Chaque connexion est un `actor`**. Attention à la réentrance : un actor peut
  exécuter une autre méthode pendant un `await`. FTP n'autorise qu'une commande à la
  fois, d'où `FTPFileSystem.exclusive { }` qui sérialise explicitement. Règle : ne
  jamais appeler une méthode publique depuis l'intérieur d'un `exclusive`.
- **Chaque transfert ouvre sa propre connexion** (`TransferQueue.run`) : la navigation
  reste fluide pendant les transferts et l'annulation (`Task.cancel()`) d'un transfert
  ne perturbe pas la session de la fenêtre.
- La progression est **limitée à ~10 mises à jour/s** (`ProgressThrottle`) pour ne pas
  saturer le main actor.
- Les libs non annotées `Sendable` (Citadel) sont importées en `@preconcurrency` ;
  leurs objets ne sortent jamais de l'actor qui les possède.

## 5. Recettes

### Ajouter un protocole (ex. WebDAV)
1. `ConnectionProtocol` : ajouter le cas (+ `displayName`, `defaultPort`, `urlScheme`).
2. Le compilateur signale chaque `switch` à compléter (dont `ProtocolFileSystemFactory`).
3. Créer un module `MaxFtpWebDAV` avec un `actor WebDAVFileSystem: RemoteFileSystem`
   qui n'implémente que les primitives.
4. Le déclarer dans `Package.swift` et l'ajouter aux dépendances de `MaxFtpApp`.
5. Rien à changer dans `MaxFtpFeatures`.

### Ajouter une action sur les fichiers (ex. « Dupliquer »)
1. Méthode dans `BrowserModel` utilisant `perform { fs in … }` (gère chargement + erreurs).
2. Bouton dans `BrowserContextMenu` (et éventuellement `BrowserCommands`).
3. Test dans `Tests/MaxFtpFeaturesTests` avec `InMemoryFileSystem`.

### Ajouter un champ à un favori
Ajouter la propriété à `ServerBookmark` **et** la décoder avec `decodeIfPresent` +
valeur par défaut dans `init(from:)`. Sinon les favoris existants deviennent illisibles.
Le test `decodesOlderSchemaWithDefaults` protège ce point.

### Ajouter une préférence
Clé dans `AppSettings`, contrôle dans `SettingsView`, lecture via `@AppStorage` (vue)
ou l'accesseur statique (modèle).

## 6. Organisation des fichiers

```
Sources/
  MaxFtpCore/        Models/ Protocols/ Transfers/ SSH/ Parsing/
  MaxFtpFTP/         Protocol/ (parseurs purs) Transport/ (NIO) FTPFileSystem*.swift
  MaxFtpSFTP/        SFTPFileSystem, SSHShell, SSHConnector (connexion + clé d'hôte), auth par clé
  MaxFtpS3/          S3FileSystem (R2, S3…) : signature SigV4, réponses XML, chemins → bucket/clé ;
                     CloudflareR2Analytics (métriques R2, GraphQL)
  MaxFtpTerminal/    TerminalSession (logique) + TerminalPanel (émulateur SwiftTerm), injecté
                     dans Features via TerminalPanelBuilder
  MaxFtpStorage/     JSONFileStore (générique), Keychain, favoris, known_hosts
  MaxFtpFeatures/    un dossier par fonctionnalité : Bookmarks/ Browser/ Inspector/
                     Transfers/ QuickConnect/ ExternalEditing/ HostKeys/ Settings/
                     R2Dashboard/
  MaxFtpApp/         @main + AppComposition
  MaxFtpTestSupport/ doublures en mémoire (serveur, stores)
Tests/               un target par module ; *IntegrationTests = opt-in (vrai serveur)
docs/adr/            décisions d'architecture et leurs raisons
```

## 7. Tests

- `swift test` : tests unitaires (parseurs, modèles, planification, modèles de vue).
- Tests d'intégration opt-in contre de vrais serveurs locaux :
  - FTP / FTPS : `Scripts/test-ftp-server.py` puis
    `MAXFTP_FTP_TEST_PORT=2121 MAXFTP_FTPS_TEST_PORT=2122 swift test --filter FTPIntegration`
  - SFTP : `Scripts/test-sshd.sh` (affiche la commande à lancer).
  - S3 / R2 : variables `MAXFTP_S3_TEST_*` (voir `S3IntegrationTests.swift`) puis
    `swift test --filter S3Integration`.
- Toute logique non triviale doit vivre dans une fonction pure ou derrière un protocole,
  pour être testable sans réseau ni UI.
