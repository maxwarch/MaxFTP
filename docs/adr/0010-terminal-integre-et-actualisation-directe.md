# 0010 — Terminal SSH intégré et actualisation en direct

**Contexte.** On veut ouvrir un terminal à l'endroit où l'on navigue, idéalement
dans l'application, et voir aussitôt dans l'explorateur ce qu'on y crée.
FTP (et S3) n'offrent aucun shell : seul SSH le permet.

**Décision.**
- Port `RemoteShell` (Core) ; implémentation `SSHShell` (MaxFtpSFTP) sur le
  pseudo-terminal de Citadel (`withPTY`, macOS 15+), avec **sa propre connexion**
  (comme les transferts, ADR 0005) ouverte par `SSHConnector`, désormais partagé avec
  `SFTPFileSystem` : mêmes identifiants, même confirmation de clé d'hôte (ADR 0007).
- Émulateur : **SwiftTerm** (1.19.x, MIT), isolé dans le module `MaxFtpTerminal`
  (Core + SwiftTerm). `MaxFtpFeatures` ne le connaît pas : la composition root lui
  injecte un `TerminalPanelBuilder` qui renvoie une `AnyView`. La version 1.99 de
  SwiftTerm prépare une 2.0 incompatible : on reste sur 1.19.
- Ouverture dans le dossier : la session tape ` cd -- '<dossier>' && clear`
  (espace initial = hors historique), plutôt qu'une commande `exec` qui dépendrait
  du shell distant.
- Alternative externe : un script `.command` éphémère (`ssh -t … cd <dossier>`)
  ouvert par l'application associée (Terminal.app, iTerm). Aucun secret n'y figure :
  `ssh` demande lui-même le mot de passe.
- Actualisation en direct, sans surveillance côté serveur (pas d'inotify par SFTP) :
  1. `TerminalSession` repère la fin d'une commande (Entrée, puis 400 ms sans sortie)
     et déclenche `BrowserModel.refreshInBackground()` ;
  2. une minuterie relit le dossier courant (5 s par défaut, réglable, uniquement
     app au premier plan, **jamais en S3** où chaque listage est facturé).
  L'actualisation discrète n'affiche ni indicateur ni erreur, conserve la sélection et
  s'abandonne si l'utilisateur a changé de dossier entre-temps.

**Conséquences.**
- Sous macOS 14, le terminal intégré affiche une erreur invitant à « Ouvrir dans Terminal ».
- Une connexion SSH de plus par terminal ouvert.
- Les modifications faites par d'autres clients apparaissent avec au plus l'intervalle
  de la minuterie de retard ; en FTP, chaque relecture ouvre un canal de données.
