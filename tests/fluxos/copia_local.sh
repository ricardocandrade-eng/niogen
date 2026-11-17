#!/usr/bin/env bash
# NIOGEN | tests/fluxos/copia_local.sh | 17/11/2026 — Claude Code
# Resumo: monta, NESTA máquina, a cópia do banco em que o portão dos fluxos roda (tests/fluxos/portao.py).
# Lê o pacote mais recente de ~/backups/niogen (scripts/backup_banco.sh) e restaura num PostgreSQL 17 local
# (porta 54329, só 127.0.0.1). NÃO toca a produção: não abre conexão nenhuma com a Supabase.
#
# O que é "de mentira" na cópia (prelude abaixo): os papéis da Supabase, auth.uid()/auth.role() (leem o mesmo
# request.jwt.claims da Supabase — é assim que o portão troca de usuário), o cofre (vault) vazio e net.http_post,
# que só anota a chamada em sim.http_posts. Resultado: nenhum cenário consegue falar com n8n, Chatwoot ou cliente.
#
# A cópia tem DADO DE CLIENTE DA NIO: fica em ~/niogen_sim, fora do Drive e do repo. Não copiar para lugar nenhum.
#
# Uso (Git Bash):  tests/fluxos/copia_local.sh            # restaura o pacote mais recente
# Variáveis: PG_SERVER_BIN (padrão ~/tools/pgsql17_server/pgsql/bin) · NIOGEN_SIM_DIR (padrão ~/niogen_sim)
set -Eeuo pipefail

BIN="${PG_SERVER_BIN:-$HOME/tools/pgsql17_server/pgsql/bin}"
SIM="${NIOGEN_SIM_DIR:-$HOME/niogen_sim}"
PORTA=54329
BANCO=niogen_sim
PSQL=("$BIN/psql.exe" -h 127.0.0.1 -p "$PORTA" -U postgres -X -q)

case "$SIM" in *"Meu Drive"*|*GitHub*) echo "ERRO: a cópia não pode ficar no Drive nem no repo." >&2; exit 1;; esac
[ -x "$BIN/postgres.exe" ] || { echo "ERRO: servidor PostgreSQL não achado em $BIN" >&2; exit 1; }

PACOTE="$(ls -1t "$HOME"/backups/niogen/niogen_backup_*.tar.gz 2>/dev/null | head -1)"
[ -n "$PACOTE" ] || { echo "ERRO: nenhum pacote em ~/backups/niogen" >&2; exit 1; }
echo "Pacote: $PACOTE"

mkdir -p "$SIM"
if [ ! -d "$SIM/pgdata" ]; then
  "$BIN/initdb.exe" -D "$SIM/pgdata" -U postgres -E UTF8 --locale=C -A trust > "$SIM/initdb.log" 2>&1
fi
if ! "$BIN/pg_isready.exe" -h 127.0.0.1 -p "$PORTA" >/dev/null 2>&1; then
  # pg_ctl segura a saída do terminal no Windows: sobe solto e espera ficar pronto
  ( "$BIN/pg_ctl.exe" -D "$SIM/pgdata" -o "-p $PORTA -c listen_addresses=127.0.0.1" -l "$SIM/pg.log" start >/dev/null 2>&1 & )
  for _ in $(seq 1 30); do "$BIN/pg_isready.exe" -h 127.0.0.1 -p "$PORTA" >/dev/null 2>&1 && break; sleep 1; done
fi

rm -rf "$SIM/pacote"; mkdir -p "$SIM/pacote"; tar xzf "$PACOTE" -C "$SIM/pacote"
basename "$PACOTE" > "$SIM/pacote_origem.txt"   # o portão grava de que backup a cópia veio

"${PSQL[@]}" -d postgres -c "drop database if exists $BANCO with (force)" -c "create database $BANCO"

# ---- prelude: o que a Supabase dá e o PostgreSQL puro não tem
"${PSQL[@]}" -d "$BANCO" -v ON_ERROR_STOP=1 <<'SQL'
do $$ declare r text; begin
  foreach r in array array['anon','authenticated','service_role','authenticator','supabase_admin','dashboard_user',
                           'supabase_auth_admin','supabase_storage_admin','pgbouncer','supabase_read_only_user'] loop
    if not exists (select 1 from pg_roles where rolname = r) then execute format('create role %I nologin', r); end if;
  end loop;
end $$;
grant anon, authenticated, service_role to postgres;
create schema if not exists extensions; create schema if not exists auth; create schema if not exists vault;
create schema if not exists net; create schema if not exists sim;
create extension if not exists pgcrypto with schema extensions;
create extension if not exists "uuid-ossp" with schema extensions;
grant usage on schema extensions, auth, net, vault to public;

create or replace function auth.uid() returns uuid language sql stable as $f$
  select nullif(coalesce(current_setting('request.jwt.claim.sub', true),
                         current_setting('request.jwt.claims', true)::jsonb ->> 'sub'), '')::uuid $f$;
create or replace function auth.role() returns text language sql stable as $f$
  select coalesce(nullif(current_setting('request.jwt.claim.role', true), ''),
                  current_setting('request.jwt.claims', true)::jsonb ->> 'role') $f$;
create or replace function auth.jwt() returns jsonb language sql stable as $f$
  select coalesce(nullif(current_setting('request.jwt.claims', true), ''), '{}')::jsonb $f$;
create table auth.users (id uuid primary key, email text, raw_user_meta_data jsonb, raw_app_meta_data jsonb,
                         created_at timestamptz default now(), last_sign_in_at timestamptz);
grant select on auth.users to public;

create table vault.decrypted_secrets (name text, decrypted_secret text);
grant select on vault.decrypted_secrets to public;

create table sim.http_posts (id bigserial primary key, em timestamptz default clock_timestamp(), url text, body jsonb);
grant all on schema sim to public; grant all on all tables in schema sim to public; grant all on all sequences in schema sim to public;
create or replace function net.http_post(url text, body jsonb default '{}'::jsonb, params jsonb default '{}'::jsonb,
    headers jsonb default '{}'::jsonb, timeout_milliseconds int default 5000) returns bigint
  language plpgsql security definer as $f$
declare i bigint; begin insert into sim.http_posts(url, body) values (url, body) returning id into i; return i; end $f$;

alter database niogen_sim set search_path = "$user", public, extensions;
alter database niogen_sim set timezone = 'UTC';
SQL

# ---- estrutura (sem as extensões que só existem na Supabase)
grep -v -E '^(CREATE EXTENSION IF NOT EXISTS "(pg_cron|pg_net|pg_stat_statements|supabase_vault|pgcrypto|uuid-ossp)"|COMMENT ON EXTENSION )' \
  "$SIM/pacote/schema.sql" > "$SIM/pacote/schema_local.sql"
"${PSQL[@]}" -d "$BANCO" -f "$SIM/pacote/schema_local.sql" > "$SIM/restore_schema.log" 2>&1 || true

# ---- dados: só o esquema public (auth e storage da Supabase ficam de fora)
python - "$SIM/pacote/data.sql" "$SIM/pacote/data_local.sql" <<'PY'
import sys, re
src, dst = sys.argv[1], sys.argv[2]
pula = False
with open(src, encoding='utf-8', newline='') as f, open(dst, 'w', encoding='utf-8', newline='') as g:
    for l in f:
        if pula:
            if l.rstrip('\r\n') == '\\.': pula = False
            continue
        if re.match(r'COPY "(auth|storage|vault|net|cron|supabase_functions|realtime)"\.', l):
            pula = True; continue
        if re.search(r"setval\('\"(auth|storage|vault|net|cron|supabase_functions|realtime)\"\.", l): continue
        g.write(l)
PY
"${PSQL[@]}" -d "$BANCO" -c "set session_replication_role = replica" -f "$SIM/pacote/data_local.sql" > "$SIM/restore_data.log" 2>&1 || true

"${PSQL[@]}" -d "$BANCO" -c "insert into auth.users (id, email) select id, email from public.usuarios on conflict do nothing" >/dev/null 2>&1 || \
"${PSQL[@]}" -d "$BANCO" -c "insert into auth.users (id) select id from public.usuarios on conflict do nothing" >/dev/null

echo "Erros na estrutura: $(grep -c 'ERROR' "$SIM/restore_schema.log" || true)   (detalhe: $SIM/restore_schema.log)"
echo "Erros nos dados:    $(grep -c 'ERROR' "$SIM/restore_data.log" || true)   (detalhe: $SIM/restore_data.log)"
"${PSQL[@]}" -d "$BANCO" -At -c "select 'funcoes='||(select count(*) from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='public' and prokind='f')
  ||' gatilhos='||(select count(*) from pg_trigger t join pg_class c on c.oid=t.tgrelid join pg_namespace n on n.oid=c.relnamespace where not tgisinternal and n.nspname='public')
  ||' conversas='||(select count(*) from public.mari_conversas)||' vendas='||(select count(*) from public.vendas)
  ||' turnos='||(select count(*) from public.mari_turnos)"
