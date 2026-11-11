#!/bin/sh
# NIOGEN | dfv/testar.sh | 11/11/2026 — Claude Code
# Na VPS (/opt/niogen/dfv): espera o operador subir e roda o aceite pela rede interna (sem expor o token na tela).
# Uso: sh testar.sh [URL_BASE]   (padrão http://niogen-dfv:8091 pela rede renata_web)
BASE=${1:-http://niogen-dfv:8091}
cd "$(dirname "$0")"
TOK=$(grep '^DFV_OP_TOKEN=' .env | cut -d= -f2-)
i=0
until docker logs niogen-dfv 2>&1 | grep -q 'ouvindo na porta'; do i=$((i+1)); [ $i -gt 90 ] && echo 'não subiu em 3 min' && exit 1; sleep 2; done
docker logs niogen-dfv 2>&1 | grep 'login' | tail -1
pedir() { docker run --rm --network renata_web -e TOK="$TOK" alpine:3.20 sh -c "wget -qO- --header \"Authorization: Bearer \$TOK\" \"$BASE$1\""; }
for q in 'cep=36010000&numero=241' 'cep=36010000&numero=' 'cep=36010000&numero=9999' 'cep=31520230&numero=100'; do
  printf '%s → ' "$q"
  pedir "/dfv?$q" | python3 -c 'import json,sys; d=json.load(sys.stdin); print({k: d.get(k) for k in ("match","viabilidade","faixa_credito_bairro","logradouro","bairro","metodo","ms","total_fachadas_no_cep","atualizado_painel")}, d.get("regra_200m",{}).get("status"))'
done
printf 'sem token → '; docker run --rm --network renata_web alpine:3.20 sh -c "wget -S -qO- $BASE/saude 2>&1 | grep -m1 HTTP"
docker stats --no-stream --format '{{.Name}} {{.MemUsage}}' niogen-dfv
