# 0005 — Une connexion dédiée par transfert

**Contexte.** FTP n'exécute qu'une commande à la fois par session. Faire passer les
transferts par la connexion de la fenêtre bloquerait la navigation pendant un upload.

**Décision.** `TransferQueue` crée une connexion neuve via la factory pour chaque
élément de la file (nombre simultané réglable, 2 par défaut), et la ferme à la fin.
Un dossier est transféré par une seule connexion, étape par étape (`TransferPlan`).

**Conséquences.**
- Navigation fluide pendant les transferts ; annuler un transfert ne casse pas la session.
- Coût d'une poignée de main supplémentaire par transfert (négligeable face au transfert).
- Les aperçus (< 5 Mo) utilisent la connexion de la fenêtre. En FTP, si un aperçu est
  annulé en cours de route, la session est fermée et rouverte automatiquement à
  l'opération suivante (`FTPFileSystem.withDataConnection`).
