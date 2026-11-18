# 0002 — FTP/FTPS sur SwiftNIO plutôt que Network.framework

**Contexte.** Le FTPS *explicite* (le plus répandu) démarre en clair puis passe en TLS
après `AUTH TLS` (STARTTLS). `NWConnection` ne permet pas d'ajouter TLS à une connexion
TCP déjà ouverte.

**Décision.** Transport FTP sur SwiftNIO + NIOSSL (déjà présents via Citadel) : on
insère `NIOSSLClientHandler` en tête du pipeline au moment voulu. Tout le code NIO est
confiné dans `MaxFtpFTP/Transport` (`NIOByteStream`, `ActiveModeListener`).

**Conséquences.**
- TLS assuré par BoringSSL (NIOSSL), pas par la pile TLS d'Apple.
- **Limite connue :** NIOSSL ne réutilise pas la session TLS du canal de contrôle sur
  le canal de données. Les serveurs qui l'exigent (vsftpd avec `require_ssl_reuse=YES`,
  sa valeur par défaut) refuseront les transferts FTPS. Contournement côté serveur :
  `require_ssl_reuse=NO`. Correctif futur : implémenter la reprise de session.
- Contrôle de flux en réception : `InboundBuffer` suspend `ChannelOptions.autoRead` au-delà de
  2 Mio en attente et le réactive sous 512 Kio, ce qui borne l'empreinte mémoire lors de
  téléchargements rapides vers un disque lent.
- Remplacer NIO par Network.framework ne toucherait que `Transport/`.
