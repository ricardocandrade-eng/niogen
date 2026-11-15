#!/bin/sh
# NIOGEN | push/instalar.sh | 15/11/2026 — Claude Code
# Roda NA VPS do n8n, dentro de /opt/niogen/push (os arquivos chegam por scp a partir do clone):
#   scp -i ~/.ssh/id_ed25519_vero push/{package.json,servidor.js,Dockerfile,docker-compose.yml,instalar.sh} root@45.32.161.130:/opt/niogen/push/
#   ssh -i ~/.ssh/id_ed25519_vero root@45.32.161.130 'sh /opt/niogen/push/instalar.sh'
# Gera as chaves VAPID só na primeira vez (o .env existente nunca é sobrescrito) e nunca as imprime.
set -eu
cd /opt/niogen/push
docker compose build -q
if [ ! -s .env ] || ! grep -q '^VAPID_PRIVADA=' .env; then
  umask 077
  docker run --rm niogen-push:1 node -e "const k=require('web-push').generateVAPIDKeys();process.stdout.write('VAPID_PUBLICA='+k.publicKey+'\nVAPID_PRIVADA='+k.privateKey+'\n')" > .env
  chmod 600 .env
  echo "chaves VAPID geradas em /opt/niogen/push/.env (não impressas)"
fi
docker compose up -d
sleep 2
docker exec niogen-push wget -qO- http://127.0.0.1:8096/saude && echo
echo "n8n alcança? (renata-n8n-1 → niogen-push)"
docker exec renata-n8n-1 wget -qO- http://niogen-push:8096/saude && echo
