# 0007 — Confirmation des clés d'hôte SSH hors de la poignée de main

**Contexte.** La confirmation d'une clé d'hôte inconnue (« Faire confiance ? ») était
demandée depuis le callback de validation de Citadel/NIOSSH, donc PENDANT la poignée de
main. Citadel y applique ses propres délais (10 s) : un utilisateur qui lisait l'empreinte
voyait la connexion échouer (« Connect timeout (10 s) ») même après avoir accepté.
Le délai global de connexion de l'app (30 s) avait le même défaut.

**Décision.** `HostKeyTrustPolicy` fonctionne en deux temps :
1. `untrustedStatus(of:)` — vérification silencieuse et immédiate pendant la poignée de
   main ; une clé inconnue ou changée fait échouer la tentative (la clé est notée).
2. `confirm(_:)` — question posée à l'utilisateur hors connexion (aucun délai ne court),
   puis `SFTPFileSystem` se reconnecte ; la clé acceptée est reconnue à l'étape 1.

`UserPromptTracker` signale qu'une question est ouverte ; `withTimeout(pausedWhile:)`
suspend alors le délai global de `BrowserModel.connect`.

**Conséquences.**
- Une première connexion à un serveur inconnu ouvre deux connexions TCP (la première
  s'arrête avant l'authentification) : coût négligeable.
- Si la clé change entre les deux tentatives, la seconde échoue en `hostKeyRejected`.
- Toute future question posée pendant une connexion (mot de passe, passphrase…) doit
  passer par `UserPromptTracker.during` pour ne pas consommer le délai.
