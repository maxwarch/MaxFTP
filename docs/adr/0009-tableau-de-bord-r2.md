# 0009 — Tableau de bord R2 via l'API GraphQL de Cloudflare

**Contexte.** On veut voir, pour un compte Cloudflare R2, le stockage utilisé, les
requêtes de classe A / B et le budget par rapport au niveau gratuit (10 Go-mois,
1 M de classe A, 10 M de classe B par mois). L'API S3 n'expose aucune de ces
métriques ; lister tous les objets pour calculer la taille coûterait en plus des
opérations de classe A.

**Décision.**
- Source : l'API GraphQL d'analytique (`r2StorageAdaptiveGroups`,
  `r2OperationsAdaptiveGroups`), port `R2UsageProvider` (Core), implémentation
  `CloudflareR2Analytics` (MaxFtpS3), transport injectable pour les tests.
- Cette API exige un **jeton d'API Cloudflare** (permission « Account Analytics :
  Read »), distinct des clés S3. Il est demandé dans le tableau de bord et rangé
  dans le trousseau sous `cloudflare-analytics:<id-compte>`, partagé par tous les
  favoris du même compte. L'identifiant de compte est déduit du point de
  terminaison (`<id>.r2.cloudflarestorage.com`) : rien à ajouter au favori.
- Calculs purs dans `R2Bill` (Core) : classification des opérations selon la grille
  publiée (action inconnue = classe A, pour ne pas sous-estimer), GB-mois = moyenne
  des pics journaliers sur 30 jours (méthode Cloudflare), projection sur le mois,
  coût au-delà du gratuit. 1 Go = 10⁹ octets (la grille ne le précise pas).
- Période : mois calendaire UTC (l'API limite une requête à 31 jours).

**Conséquences.**
- Le bouton n'apparaît que pour une connexion S3 vers un point de terminaison R2.
- Estimation, pas facture : la période de facturation réelle du compte peut ne pas
  coïncider avec le mois calendaire, et les métriques ont quelques minutes de retard.
- Les tarifs sont codés en dur (`R2Pricing.standard`) : à mettre à jour s'ils changent.
- Au-delà de 10 000 relevés de stockage sur le mois (nombreux buckets), les jours
  les plus anciens sont ignorés dans le calcul des GB-mois.
