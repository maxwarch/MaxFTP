# 0004 — App Sandbox désactivé

**Contexte.** L'app lit `~/.ssh/config`, `~/.ssh/known_hosts` et les clés privées, et
ouvre des fichiers dans des éditeurs externes en surveillant leurs sauvegardes.

**Décision.** `com.apple.security.app-sandbox = false` (`Resources/MaxFtp.entitlements`).

**Conséquences.**
- Pas de distribution sur le Mac App Store. Distribution directe : signer avec un
  certificat Developer ID, Hardened Runtime (`--options runtime`), puis notariser.
- L'app n'écrit jamais dans `~/.ssh` (lecture seule) : les clés d'hôte approuvées
  vont dans `Application Support/MaxFtp/known_hosts.json`.
