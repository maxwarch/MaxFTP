# Décisions d'architecture (ADR)

Chaque décision structurante est consignée ici avec son contexte et ses conséquences,
pour qu'on sache plus tard *pourquoi* le code est ainsi, et quand il est légitime de
revenir dessus. Nouvelle décision → nouveau fichier `NNNN-titre.md` (ne pas réécrire
une ADR acceptée : en créer une qui la remplace).

| # | Décision | Statut |
|---|---|---|
| [0001](0001-swift-package-multi-modules.md) | Swift Package multi-modules | Acceptée |
| [0002](0002-ftp-sur-swiftnio.md) | FTP/FTPS sur SwiftNIO plutôt que Network.framework | Acceptée |
| [0003](0003-favoris-json-plutot-que-swiftdata.md) | Favoris en JSON plutôt que SwiftData | Acceptée |
| [0004](0004-app-sandbox-desactive.md) | App Sandbox désactivé | Acceptée |
| [0005](0005-une-connexion-par-transfert.md) | Une connexion dédiée par transfert | Acceptée |
| [0006](0006-signets-par-serveur.md) | Signets rattachés au serveur, stockés à part | Acceptée |
| [0007](0007-confirmation-cle-hote-hors-poignee-de-main.md) | Confirmation des clés d'hôte SSH hors de la poignée de main | Acceptée |
| [0008](0008-stockage-s3-r2.md) | Stockage objet S3 / Cloudflare R2 sans SDK | Acceptée |
| [0009](0009-tableau-de-bord-r2.md) | Tableau de bord R2 via l'API GraphQL de Cloudflare | Acceptée |
| [0010](0010-terminal-integre-et-actualisation-directe.md) | Terminal SSH intégré et actualisation en direct | Acceptée |
