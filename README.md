# MaxFtp

Client **FTP / FTPS / SFTP** 100 % natif pour macOS 14+ — Swift 6, SwiftUI, AppKit.
Aucune technologie web.

## Démarrage

```bash
make test        # tests unitaires
make run         # construit build/MaxFtp.app et l'ouvre
open Package.swift   # ouvrir dans Xcode (schéma « MaxFtp »)
```

Prérequis : Xcode 16+ ou Command Line Tools avec Swift 6.

## Fonctionnalités

- **Favoris** (barre latérale) : SFTP, FTP, FTPS explicite/implicite ; mot de passe
  ou clé SSH (ed25519, RSA, avec passphrase) ; secrets dans le **trousseau macOS**.
- **Connexion rapide** : `sftp://user@hôte:port/chemin`, `user@hôte`, ou un alias de
  `~/.ssh/config` (HostName, User, Port, IdentityFile résolus).
- **Explorateur** : `Table` native triable (nom, taille, date, permissions `rwxr-xr-x 0755`),
  fil d'Ariane cliquable (on peut y déposer des fichiers), menu contextuel : nouveau
  dossier, renommer, supprimer (récursif), CHMOD, télécharger, éditer / éditer avec…
- **Glisser-déposer** depuis le Finder (fichiers et dossiers entiers).
- **File de transferts** (popover) : progression, vitesse, annulation, transferts simultanés.
- **Inspecteur** : icône système, métadonnées, aperçu automatique (< 5 Mo) — images,
  texte/code en monospace, sinon QuickLook (`QLPreviewView`). **Espace** = QuickLook plein.
- **Édition externe** : le fichier est ré-uploadé à chaque sauvegarde dans l'éditeur.
- **Sécurité SSH** : vérification des clés d'hôte (`~/.ssh/known_hosts`, y compris
  entrées hachées), alerte renforcée si une clé change.

Raccourcis : ⌘R actualiser · ⌘↑ dossier parent · ⇧⌘N nouveau dossier · ⌘U envoyer ·
⌥⌘I inspecteur · ⌫ supprimer · Espace aperçu · ⌘, réglages.

## Architecture

Voir **[ARCHITECTURE.md](ARCHITECTURE.md)** (modules, patterns, recettes pour étendre)
et les décisions dans **[docs/adr](docs/adr/README.md)**.

## Limites connues

- FTPS : pas de reprise de session TLS sur le canal de données (voir ADR 0002).
- SFTP : seul le format OpenSSH des clés est géré (pas les anciennes clés PEM
  `BEGIN RSA PRIVATE KEY` ; les convertir avec `ssh-keygen -p -f clé`).
- Clés ECDSA et agent SSH (`ssh-agent`) non pris en charge pour l'instant.
- Glisser des fichiers distants **vers** le Finder : pas encore implémenté (utiliser « Télécharger… »).
