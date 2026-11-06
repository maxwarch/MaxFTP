#!/usr/bin/env python3
"""Serveur FTP + FTPS (TLS explicite) jetable pour les tests d'intégration.

Usage :
    python3 -m venv .venv && .venv/bin/pip install pyftpdlib pyopenssl
    .venv/bin/python Scripts/test-ftp-server.py
    # puis, dans un autre terminal :
    MAXFTP_FTP_TEST_PORT=2121 MAXFTP_FTPS_TEST_PORT=2122 swift test --filter FTPIntegration

Identifiants : user / pass. Racine : un nouveau dossier temporaire à chaque lancement.
"""
import subprocess
import tempfile
from pathlib import Path

from pyftpdlib.authorizers import DummyAuthorizer
from pyftpdlib.handlers import FTPHandler, TLS_FTPHandler
from pyftpdlib.servers import FTPServer

root = Path(tempfile.mkdtemp(prefix="maxftp-ftp-"))
home = root / "home"
home.mkdir()

authorizer = DummyAuthorizer()
authorizer.add_user("user", "pass", str(home), perm="elradfmwMT")

cert = root / "cert.pem"
subprocess.run(
    ["openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "1",
     "-subj", "/CN=localhost", "-keyout", str(cert), "-out", str(cert)],
    check=True, capture_output=True,
)


class PlainHandler(FTPHandler):
    authorizer = authorizer
    permit_foreign_addresses = True


class TLSHandler(TLS_FTPHandler):
    authorizer = authorizer
    certfile = str(cert)
    tls_control_required = True
    tls_data_required = True


# Les deux serveurs partagent la même IOLoop : une seule boucle les sert tous les
# deux. (La faire tourner depuis deux threads corrompt les transferts.)
plain = FTPServer(("127.0.0.1", 2121), PlainHandler)
FTPServer(("127.0.0.1", 2122), TLSHandler)
print(f"FTP sur 2121, FTPS explicite sur 2122, racine {home}", flush=True)
plain.serve_forever()
