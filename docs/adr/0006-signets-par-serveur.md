# 0006 — Signets rattachés au serveur, stockés à part

**Contexte.** L'utilisateur veut, comme dans un navigateur web, des raccourcis vers
des dossiers ou fichiers précis de chaque serveur. Une session peut venir d'un favori
(`ServerBookmark`) ou de la connexion rapide, qui n'a pas de favori.

**Décision.** Les signets (`PathBookmark`) sont indexés par `ConnectionConfiguration.serverKey`
(`protocole://utilisateur@hôte:port`, hôte en minuscules) et stockés dans un fichier à part,
`path-bookmarks.json`, via le port `PathBookmarkRepository`. `ServerBookmark` n'est pas modifié.

**Conséquences.**
- Affichage : chaque favori se déplie sur les signets de sa `serverKey` ; cliquer un
  signet connecte au favori si besoin et arrive directement dessus. Les signets d'une
  session sans favori apparaissent dans une section « Signets de la session ».
- Mêmes signets que l'on passe par un favori ou par la connexion rapide.
- `bookmarks.json` reste inchangé : aucune migration.
- Changer l'hôte, le port, l'utilisateur ou le protocole d'un favori « orphelise » ses
  signets (ils restent dans le fichier, rattachés à l'ancienne identité). Si cela gêne,
  ajouter une migration de clé dans `BookmarksModel.save`.
- Supprimer un favori ne supprime pas ses signets (un autre favori ou la connexion
  rapide peut viser le même serveur).
