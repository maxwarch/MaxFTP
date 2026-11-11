# 0008 — Stockage objet S3 / Cloudflare R2 sans SDK

**Contexte.** On veut gérer un bucket Cloudflare R2. R2 expose l'API S3 ; un
adaptateur S3 générique couvre donc aussi AWS S3, MinIO, Backblaze B2, etc. Or S3
n'est pas un système de fichiers : pas de dossiers, pas de renommage, pas de
permissions POSIX, et `RemoteFileSystem` raisonne en chemins.

**Décision.**
- Nouveau cas `ConnectionProtocol.s3` et module `MaxFtpS3`, qui ne dépend que de
  Core, Foundation (`URLSession`, `XMLParser`) et CryptoKit. Pas de SDK AWS : la
  signature SigV4 (~80 lignes, testée avec les vecteurs officiels AWS) et quatre
  réponses XML ne justifient pas une dépendance lourde.
- Correspondance des chemins (`S3Location`) : le premier composant est le bucket,
  le reste la clé. `/` liste les buckets ; un dossier est un préfixe `clé/`, listé
  avec `delimiter=/`. Créer un dossier écrit un objet vide `dossier/` (convention
  de la console R2/S3) pour qu'il reste visible tant qu'il est vide.
- Adressage « path-style » (`https://hôte/bucket/clé`), accepté par R2 et S3.
- Identifiants : `username` = Access Key ID, mot de passe (trousseau) = Secret
  Access Key. Région dans `s3Region` (`auto` pour R2).
- Renommer = `CopyObject` + `DELETE`, objet par objet pour un dossier.
  `setPermissions` lève `RemoteError.unsupportedOperation` et l'UI masque CHMOD.
- Uploads : `PUT` simple jusqu'à 100 Mio, multipart au-delà (parties de taille
  fixe, exigence de R2), abandon explicite en cas d'échec. Corps non haché
  (`UNSIGNED-PAYLOAD`, HTTPS uniquement) pour ne pas relire les fichiers.

**Conséquences.**
- Rien à changer dans `MaxFtpFeatures` hormis l'éditeur de favori et le masquage
  de CHMOD ; transferts, signets, aperçu et édition externe fonctionnent tels quels.
- Renommer un gros dossier coûte une copie par objet ; `CopyObject` est limité à
  5 Go par objet (au-delà il faudrait `UploadPartCopy`).
- Un jeton R2 limité à un bucket ne peut pas lister les buckets : l'utilisateur
  indique alors `/bucket` comme dossier initial (vérifié à la connexion).
- Pas de prise en charge de l'adressage « virtual-hosted » seul ni des sessions STS.
