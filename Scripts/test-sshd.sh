#!/usr/bin/env bash
# Serveur SSH/SFTP jetable (sans root) pour les tests d'intégration SFTP.
#
# Usage :
#   Scripts/test-sshd.sh            # affiche la commande `swift test` à lancer
#
# Utilise le sshd de macOS sur 127.0.0.1:2222 avec des clés générées dans un
# dossier temporaire. Seul l'utilisateur courant peut se connecter (par clé).
set -euo pipefail

PORT="${PORT:-2222}"
DIR="$(mktemp -d -t maxftp-sshd)"
cd "$DIR"

ssh-keygen -q -t ed25519 -N "" -f host_key
ssh-keygen -q -t ed25519 -N "" -f client_key
ssh-keygen -q -t ed25519 -N "s3cret" -f client_key_enc
cat client_key.pub client_key_enc.pub > authorized_keys
chmod 600 authorized_keys

cat > sshd_config <<EOF
Port $PORT
ListenAddress 127.0.0.1
HostKey $DIR/host_key
PidFile $DIR/sshd.pid
AuthorizedKeysFile $DIR/authorized_keys
PasswordAuthentication no
KbdInteractiveAuthentication no
UsePAM no
StrictModes no
Subsystem sftp /usr/libexec/sftp-server
EOF

cat <<EOF
sshd démarré sur 127.0.0.1:$PORT (Ctrl-C pour arrêter). Dans un autre terminal :

  MAXFTP_SFTP_TEST_PORT=$PORT MAXFTP_SFTP_TEST_KEY=$DIR/client_key \\
  MAXFTP_SFTP_TEST_ENCRYPTED_KEY=$DIR/client_key_enc MAXFTP_SFTP_TEST_PASSPHRASE=s3cret \\
  swift test --filter SFTPIntegration

EOF
exec /usr/sbin/sshd -D -e -f "$DIR/sshd_config"
