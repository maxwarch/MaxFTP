# MaxFtp

Client **FTP / FTPS / SFTP / S3 (Cloudflare R2)** 100 % natif pour macOS 14+ — Swift 6, SwiftUI, AppKit.
Aucune technologie web.

## Installation

1. Téléchargez **`MaxFtp-<version>.dmg`** depuis la page
   [Releases](https://github.com/maxwarch/MaxFTP/releases/latest) (Mac Apple Silicon ou Intel, macOS 14+).
2. Ouvrez le `.dmg` et glissez **MaxFtp** dans **Applications**.
3. **Premier lancement uniquement** : l'app n'est pas (encore) notarisée par Apple, macOS
   la bloque (« Apple n'a pas pu vérifier… »). Cliquez **OK**, puis ouvrez
   **Réglages Système › Confidentialité et sécurité**, descendez jusqu'à
   « MaxFtp a été bloquée » et cliquez **Ouvrir quand même** (mot de passe du Mac demandé).
   Ensuite, MaxFtp s'ouvre normalement.

   Alternative en Terminal : `xattr -dr com.apple.quarantine /Applications/MaxFtp.app`

## Compiler depuis les sources

```bash
make test        # tests unitaires
make run         # construit build/MaxFtp.app et l'ouvre
Scripts/package-release.sh   # .dmg universel (Apple Silicon + Intel) dans build/
```

Prérequis : Xcode 16+ ou Command Line Tools avec Swift 6.

## Fonctionnalités

- **Favoris** (barre latérale) : SFTP, FTP, FTPS explicite/implicite, **S3 / Cloudflare R2** ;
  mot de passe ou clé SSH (ed25519, RSA, avec passphrase) ; secrets dans le **trousseau macOS**.
- **Cloudflare R2 / S3** : point de terminaison `<id-compte>.r2.cloudflarestorage.com`,
  Access Key ID + Secret Access Key d'un jeton d'API R2, région `auto`. La racine liste
  les buckets ; les dossiers sont des préfixes. Création/suppression de buckets, uploads
  multipart au-delà de 100 Mio.
- **Terminal SSH intégré** (SFTP) : bouton Terminal (⌃\`) ou clic droit « Ouvrir un
  terminal ici » ; s'ouvre sous l'explorateur dans le dossier visé. « Ouvrir dans
  Terminal » lance plutôt `ssh` dans Terminal.app / iTerm. Indisponible en FTP (pas de shell).
- **Actualisation en direct** : l'explorateur se met à jour après chaque commande du
  terminal, et relit le dossier courant toutes les 5 s (réglable, jamais en S3).
- **Tableau de bord R2** (bouton graphique de la barre d'outils) : stockage, requêtes
  classe A / B et coût estimé du mois face au niveau gratuit, taille de chaque bucket.
  Demande un jeton d'API Cloudflare « Account Analytics : Read » (rangé dans le trousseau).
  Une connexion rapide s'enregistre en favori d'un clic (juste un nom à donner).
- **Signets** : dossiers ou fichiers précis rangés sous chaque favori ; un clic s'y connecte
  et y mène directement.
- **Connexion rapide** : `sftp://user@hôte:port/chemin`, `user@hôte`, ou un alias de
  `~/.ssh/config` (HostName, User, Port, IdentityFile résolus). Annulable, délai de 30 s.
- **Navigation comme un navigateur** : Précédent / Suivant (boutons, ⌘[ ⌘], boutons
  latéraux de la souris, balayage), liste des dossiers parents, fil d'Ariane cliquable.
- **Explorateur** : `Table` native triable (nom, taille, date, permissions `rwxr-xr-x 0755`),
  menu contextuel : nouveau dossier, renommer, supprimer (récursif), CHMOD, télécharger,
  éditer / éditer avec… ; fichiers cachés affichables (interrupteur, ⇧⌘.).
- **Glisser-déposer** depuis le Finder (fichiers et dossiers entiers).
- **Transferts** : indicateur discret dans la barre d'état, fenêtre dédiée (⌥⌘T) —
  progression, vitesse, annulation, transferts simultanés.
- **Inspecteur** : métadonnées et aperçu — images, texte/code, **Markdown mis en forme**,
  QuickLook ; pour un dossier, son contenu (clic sur un fichier = aperçu, sur un dossier = y aller).
- **Édition externe** : éditeur par défaut et « toujours ouvrir avec » par extension (Réglages) ;
  le fichier est ré-uploadé à chaque sauvegarde.
- **Sécurité SSH** : vérification des clés d'hôte (`~/.ssh/known_hosts`, y compris
  entrées hachées), alerte renforcée si une clé change.

Raccourcis : ⌘R actualiser · ⌘[ ⌘] précédent / suivant · ⌘↑ dossier parent ·
⌘D signet · ⇧⌘N nouveau dossier · ⌘U envoyer · ⌘⌫ supprimer · ⇧⌘. fichiers cachés ·
⌥⌘T transferts · ⌥⌘I inspecteur · Espace aperçu · ⌘, réglages.

## Architecture

Voir **[ARCHITECTURE.md](ARCHITECTURE.md)** (modules, patterns, recettes pour étendre)
et les décisions dans **[docs/adr](docs/adr/README.md)**.

## Limites connues

- FTPS : pas de reprise de session TLS sur le canal de données (voir ADR 0002).
- SFTP : seul le format OpenSSH des clés est géré (pas les anciennes clés PEM
  `BEGIN RSA PRIVATE KEY` ; les convertir avec `ssh-keygen -p -f clé`).
- Clés ECDSA et agent SSH (`ssh-agent`) non pris en charge pour l'instant.
- S3 / R2 : pas de permissions (CHMOD masqué) ; renommer un dossier copie chaque objet ;
  un objet de plus de 5 Go ne peut pas être renommé.
- Terminal intégré : macOS 15 requis (sinon « Ouvrir dans Terminal »).
- Glisser des fichiers distants **vers** le Finder : pas encore implémenté (utiliser « Télécharger… »).
