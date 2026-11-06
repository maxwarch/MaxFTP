# 0003 — Favoris en JSON plutôt que SwiftData

**Contexte.** Quelques dizaines de favoris au plus, sans relations ni requêtes.

**Décision.** `JSONBookmarkRepository` écrit `~/Library/Application Support/MaxFtp/bookmarks.json`
(écriture atomique, champ `schemaVersion`). Les secrets n'y figurent jamais : ils sont
dans le Keychain, indexés par l'UUID du favori.

**Conséquences.**
- Fichier lisible, sauvegardable, facile à déboguer ; aucune migration de schéma Core Data.
- Compatibilité ascendante assurée par `decodeIfPresent` dans `ServerBookmark`.
- Passer à SwiftData (ex. pour synchroniser via iCloud) : écrire une autre
  implémentation de `BookmarkRepository` et la brancher dans `AppComposition`.
