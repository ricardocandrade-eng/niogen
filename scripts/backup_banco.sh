#!/usr/bin/env bash
# NIOGEN | scripts/backup_banco.sh | 11/11/2026 13h50 — Claude Code
# Resumo: backup diário do banco (Supabase Nio) para o disco desta máquina. O projeto está no plano Free, sem backup
# automático (Ricardo, 11/11/2026: "Dump diário grátis"). Só LÊ o banco. Roda pela tarefa agendada do Windows
# "NIOGEN - backup diario do banco" e também à mão, no Git Bash:  scripts/backup_banco.sh
#
# Como: `supabase db dump` exige Docker, que esta máquina não tem. O --dry-run do CLI devolve a receita do pg_dump com um
# login temporário; ela roda com o cliente PostgreSQL 17 local. Nenhuma senha é digitada, impressa ou gravada: a receita
# fica só na memória do script.
#
# O pacote tem DADO DE CLIENTE DA NIO: fica só neste disco, fora do Drive e do repo (o script recusa), sem criptografia.
# Não copiar para Drive, e-mail ou chat. Como restaurar e o que o pacote não traz: INFRA.md, seção "Backup do banco".
#
# Variáveis (todas opcionais):
#   NIOGEN_BACKUP_DIR     pasta dos pacotes (padrão ~/backups/niogen)
#   NIOGEN_BACKUP_MANTER  quantos pacotes ficam (padrão 30)
#   PG_BIN                pasta bin do cliente PostgreSQL 17 (padrão ~/tools/pgsql17/pgsql/bin)
#   NIOGEN_BACKUP_AVISAR  1 = abre o aviso na tela se falhar (a tarefa agendada liga)

set -Eeuo pipefail

AQUI="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$AQUI/.." && pwd)"
CLI_VER="supabase@3.0.0"       # a 3.1.0 é bloqueada pelo Controle de Aplicativo do Windows (INFRA §3)
NPX="npx"; command -v npx.cmd >/dev/null 2>&1 && NPX="npx.cmd"
DEST="${NIOGEN_BACKUP_DIR:-$HOME/backups/niogen}"
MANTER="${NIOGEN_BACKUP_MANTER:-30}"
PG_BIN="${PG_BIN:-$HOME/tools/pgsql17/pgsql/bin}"
REF="$(tr -d '[:space:]' < "$REPO/supabase/.temp/project-ref" 2>/dev/null || true)"   # o projeto ligado ao CLI
INICIO=$SECONDS
QUANDO="$(date '+%d/%m/%Y %H:%M')"
CARIMBO="$(date '+%d%m%y_%H%M')"
WORK=""; TRAVA=""

limpa() {
  if [ -n "$WORK" ]; then rm -rf "$WORK"; fi
  if [ -n "$TRAVA" ]; then rmdir "$TRAVA" 2>/dev/null || true; fi
}

# Falhou: grava o motivo no ULTIMO_BACKUP.txt e no backup.log; com NIOGEN_BACKUP_AVISAR=1, abre o aviso no Bloco de Notas.
falha() {
  local msg="$1"
  trap - ERR
  mkdir -p "$DEST" 2>/dev/null || true
  {
    echo "BACKUP DO NIOGEN: FALHOU"
    echo "Quando: $QUANDO"
    echo "Motivo: $msg"
    echo
    echo "O banco de produção não foi alterado (o backup só lê)."
    echo "Último pacote bom: $(ls -1t "$DEST"/niogen_backup_*.tar.gz 2>/dev/null | head -1 || true)"
    echo "Para tentar de novo, no Git Bash: $AQUI/backup_banco.sh"
  } > "$DEST/ULTIMO_BACKUP.txt" 2>/dev/null || true
  echo "$QUANDO FALHOU $msg" >> "$DEST/backup.log" 2>/dev/null || true
  echo "ERRO: $msg" >&2
  if [ "${NIOGEN_BACKUP_AVISAR:-0}" = "1" ]; then
    explorer.exe "$(cygpath -w "$DEST/ULTIMO_BACKUP.txt")" >/dev/null 2>&1 || true   # abre no programa padrão de .txt
  fi
  exit 1
}
trap limpa EXIT
trap 'falha "erro inesperado na linha $LINENO"' ERR

# ───────── portões ─────────
case "$(realpath -m "$DEST")" in
  *"Meu Drive"*|*"/GitHub/"*|*"/dharmapro-nio"*|*OneDrive*) falha "a pasta do backup não pode ficar no Drive nem no repo: $DEST" ;;
esac
[[ "$REF" =~ ^[a-z]{20}$ ]] || falha "não achei o projeto ligado ao CLI (supabase/.temp/project-ref)"
export PATH="$PG_BIN:$PATH"
command -v pg_dump >/dev/null 2>&1 || falha "pg_dump não encontrado em $PG_BIN"
pg_dump --version | grep -q " 17\." || falha "precisa do cliente PostgreSQL 17 (achei: $(pg_dump --version))"
export PGSSLMODE=require PGCONNECT_TIMEOUT=20 PGCLIENTENCODING=UTF8

mkdir -p "$DEST"
# Uma execução por vez. Trava com mais de 1 h é resto de execução interrompida (PC desligado no meio): descarta.
if [ -d "$DEST/.rodando" ] && [ -n "$(find "$DEST/.rodando" -maxdepth 0 -mmin +60 2>/dev/null)" ]; then
  rmdir "$DEST/.rodando" 2>/dev/null || true
fi
mkdir "$DEST/.rodando" 2>/dev/null || falha "já tem um backup rodando (pasta $DEST/.rodando)"
TRAVA="$DEST/.rodando"
rm -rf "$DEST"/.andamento_*            # resto de execução interrompida (dump pela metade)
WORK="$DEST/.andamento_$CARIMBO"
mkdir -p "$WORK"

# ───────── dump ─────────
# dump_um <arquivo> <opções do `db dump`…>
dump_um() {
  local saida="$1"; shift
  # A receita (com o login temporário) fica só na memória: não vai para arquivo, tela nem linha de comando.
  local receita
  receita="$(cd "$REPO" && "$NPX" "$CLI_VER" db dump --remote="$REF" --dry-run "$@" 2>/dev/null)" \
    || falha "o CLI da Supabase não devolveu a receita de $saida (login do CLI vencido? rode: npx supabase@3.0.0 login)"
  [[ "$receita" == *$'\nexport PGPASSWORD='* ]] || falha "receita de $saida sem login temporário"
  [[ "$receita" == *$'\npg_dump '* || "$receita" == *$'\npg_dumpall '* ]] || falha "receita de $saida sem pg_dump"
  # A receita abrevia --quote-all-identifiers (sem o "s"); o pg_dump do Windows não aceita abreviação.
  receita="${receita//--quote-all-identifiers/--quote-all-identifier}"
  receita="${receita//--quote-all-identifier/--quote-all-identifiers}"
  printf '%s\n' "$receita" | bash > "$WORK/$saida" || falha "pg_dump falhou em $saida"
  [ -s "$WORK/$saida" ] || falha "$saida saiu vazio"
}

dump_um roles.sql      --role-only
dump_um schema.sql
dump_um data.sql       --data-only --use-copy -x storage.buckets_vectors -x storage.vector_indexes \
                       -x net._http_response -x net.http_request_queue
dump_um mig_schema.sql --schema supabase_migrations
dump_um mig_data.sql   --data-only --use-copy --schema supabase_migrations

# ───────── conferência do que saiu ─────────
# Dump de dados: o pg_dump fecha o arquivo com esta marca. A receita do dump de estrutura apaga os comentários (e a marca
# junto); nele vale a saída do pg_dump (a receita roda com pipefail) e a presença da tabela de vendas.
for f in data.sql mig_data.sql; do
  tail -n 40 "$WORK/$f" | grep -q 'PostgreSQL database dump complete' || falha "$f está incompleto (sem o fecho do pg_dump)"
done
grep -q '^CREATE TABLE IF NOT EXISTS "public"."vendas"' "$WORK/schema.sql" || falha "schema.sql não tem a tabela de vendas"

# Linhas por tabela, contadas nos blocos COPY do dump (sem dado de cliente).
conta_copy() {
  awk '
    dentro { if ($0 == "\\.") { print tabela "\t" n; dentro = 0 } else n++; next }
    /^COPY / { tabela = $2; gsub(/"/, "", tabela); n = 0; dentro = 1 }
  ' "$1"
}
conta_copy "$WORK/data.sql" > "$WORK/contagens.txt"
conta_copy "$WORK/mig_data.sql" >> "$WORK/contagens.txt"
linhas() { awk -F'\t' -v t="$1" '$1 == t { print $2; achou = 1 } END { if (!achou) print "-1" }' "$WORK/contagens.txt"; }

N_CREATE="$(grep -c '^CREATE TABLE ' "$WORK/schema.sql" || true)"
N_TAB="$(grep -c '^public\.' "$WORK/contagens.txt" || true)"
N_VENDAS="$(linhas public.vendas)"
N_TURNOS="$(linhas public.mari_turnos)"
N_USU="$(linhas auth.users)"
N_MIG="$(linhas supabase_migrations.schema_migrations)"
if [ "$N_CREATE" -lt 1 ] || [ "$N_TAB" -lt 1 ] || [ "$N_VENDAS" -lt 0 ] || [ "$N_USU" -lt 1 ] || [ "$N_MIG" -lt 1 ]; then
  falha "o dump não tem o esperado (tabelas na estrutura: $N_CREATE · tabelas de public com dados: $N_TAB · vendas: $N_VENDAS · usuários: $N_USU · migrations: $N_MIG)"
fi

# ───────── pacote ─────────
PACOTE="$DEST/niogen_backup_$CARIMBO.tar.gz"
tar -czf "$PACOTE.parcial" -C "$WORK" . || falha "não consegui compactar o pacote"
tar -tzf "$PACOTE.parcial" > /dev/null || falha "o pacote compactado não abre"
mv -f "$PACOTE.parcial" "$PACOTE"
rm -rf "$WORK"; WORK=""

# Ficam os $MANTER pacotes mais recentes.
ls -1t "$DEST"/niogen_backup_*.tar.gz | tail -n +"$((MANTER + 1))" | while IFS= read -r velho; do rm -f "$velho"; done

TAM="$(du -h "$PACOTE" | cut -f1)"
DUR=$((SECONDS - INICIO))
QTD="$(ls -1 "$DEST"/niogen_backup_*.tar.gz | wc -l | tr -d ' ')"
{
  echo "BACKUP DO NIOGEN: OK"
  echo "Quando: $QUANDO (levou $((DUR / 60)) min $((DUR % 60)) s)"
  echo "Pacote: $(cygpath -w "$PACOTE") ($TAM)"
  echo "Projeto: $REF"
  echo "Conteúdo: $N_CREATE tabelas na estrutura · $N_TAB tabelas de public com dados · vendas $N_VENDAS · mari_turnos $N_TURNOS · usuários $N_USU · migrations $N_MIG"
  echo "Pacotes guardados: $QTD (ficam os $MANTER mais recentes)"
  echo
  echo "Tem dado de cliente da Nio: não copiar para Drive, e-mail ou chat. Restore: INFRA.md, seção \"Backup do banco\"."
} > "$DEST/ULTIMO_BACKUP.txt"
echo "$QUANDO OK $(basename "$PACOTE") $TAM ${DUR}s vendas=$N_VENDAS turnos=$N_TURNOS migrations=$N_MIG" >> "$DEST/backup.log"
cat "$DEST/ULTIMO_BACKUP.txt"
