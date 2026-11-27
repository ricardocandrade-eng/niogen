-- NIOGEN | supabase/migrations/0435_banco_reinicio_alarme.sql | 27/11/2026 20h22 — Claude Code (Fable 5.2)
-- Ricardo, 27/11: "Pode seguir com o alarme de reinício e a regra 19".
-- Por quê: em 27/11 o Postgres da produção reiniciou 8 vezes numa tarde por falta de memória e ninguém soube pelo sistema — o
-- sinal foi o time vendo "Failed to fetch" e a Mari deixando lead sem resposta (L-462, L-463). O banco só sabe a hora do ÚLTIMO
-- início (pg_postmaster_start_time); os anteriores somem.
-- O que muda:
--   1. Tabela banco_reinicios: uma linha por início do Postgres.
--   2. banco_reinicio_registrar(): grava o início de agora se ainda não está na tabela (com o último sinal de vida antes dele,
--      lido do pg_cron, para dar o tamanho da parada). Roda sozinha a cada 2 min (pg_cron "banco_reinicio").
--   3. Conferência diária, item 44 "Banco: o Postgres não reiniciou nas últimas 24 h": 1 reinício = atenção, 2 ou mais = falha,
--      com os horários. Aparece no Painel e na Live › Conferir às 7h10, como os outros.
--   4. Os 8 reinícios de 27/11 entram já, lidos do log do Postgres (origem "log_postgres") — a conferência de 28/11 nasce certa.
-- Sistema fechado (regra 20): (1) não é estado de lead — não se aplica; (2) ninguém parado em silêncio: o reinício vira linha da
-- conferência, com dono cobrado (avisar o Claude Code); (3) a tabela só é gravada pela função; (4) fonte única: o próprio
-- Postgres (pg_postmaster_start_time); (5) a conferência é o item 44.
-- Regra 15: a tabela NÃO tem parceiro_id — o banco é um só para todos os parceiros; a linha é da máquina, não da operação.
-- Desempenho (regra 19): a rotina é um insert de uma linha a cada 2 min; o item da conferência lê uma tabela de poucas linhas —
-- sem impacto nas telas. Guia do backoffice: sem impacto (é aviso para o Ricardo e o Claude Code, não muda o atendimento).

begin;

-- 1. A tabela ------------------------------------------------------------------------------------------------------------------
create table if not exists public.banco_reinicios (
  subiu_em        timestamptz primary key,          -- quando o Postgres começou a aceitar conexões
  ultimo_sinal_em timestamptz,                      -- última rotina do pg_cron antes dele (a parada começou depois disso)
  visto_em        timestamptz not null default now(),
  origem          text not null default 'rotina'    -- rotina (a cada 2 min) | log_postgres (carga de 27/11)
);
comment on table public.banco_reinicios is
  '0435: uma linha por início do Postgres (o banco só guarda o último). Gravada só por banco_reinicio_registrar(). Reinício em série = falta de memória (27/11/2026; INFRA › Desempenho).';
alter table public.banco_reinicios enable row level security;   -- sem política: só as funções (definer) e a chave de serviço leem
revoke all on public.banco_reinicios from anon, authenticated;

-- 2. Quem grava -----------------------------------------------------------------------------------------------------------------
create or replace function public.banco_reinicio_registrar() returns timestamptz
language plpgsql security definer set search_path = public as $$
declare
  v_subiu timestamptz := date_trunc('second', pg_postmaster_start_time());
  v_sinal timestamptz;
begin
  if exists (select 1 from public.banco_reinicios r where r.subiu_em = v_subiu) then
    return null;                                    -- já anotado
  end if;
  begin                                             -- o último sinal de vida antes da parada (só onde há pg_cron)
    execute 'select max(d.end_time) from cron.job_run_details d where d.end_time < $1' into v_sinal using v_subiu;
  exception when others then
    v_sinal := null;
  end;
  insert into public.banco_reinicios (subiu_em, ultimo_sinal_em) values (v_subiu, v_sinal) on conflict do nothing;
  return v_subiu;
end $$;
revoke all on function public.banco_reinicio_registrar() from public, anon, authenticated;
grant execute on function public.banco_reinicio_registrar() to service_role;

-- 3. Os reinícios de 27/11/2026, lidos do log do Postgres (Supabase › Logs › Postgres, "database system was not properly shut down")
insert into public.banco_reinicios (subiu_em, origem) values
  ('2026-11-27 17:33:41-03', 'log_postgres'), ('2026-11-27 17:48:48-03', 'log_postgres'), ('2026-11-27 18:15:59-03', 'log_postgres'),
  ('2026-11-27 18:32:16-03', 'log_postgres'), ('2026-11-27 18:40:10-03', 'log_postgres'), ('2026-11-27 18:46:14-03', 'log_postgres'),
  ('2026-11-27 18:55:39-03', 'log_postgres'), ('2026-11-27 19:10:39-03', 'log_postgres')
on conflict do nothing;

-- 4. Conferência: item 44 ------------------------------------------------------------------------------------------------------
do $$
declare d text := pg_get_functiondef('public.conferencia_itens'::regproc);
begin
  if position('''banco_reinicio''' in d) > 0 then return; end if;
  if regexp_count(d, E'\\r?\\n  return it;\\r?\\nend') <> 1 then
    raise exception '0435: conferencia_itens mudou — refazer o item do reinício do banco a partir da versão no ar';
  end if;
  d := regexp_replace(d, E'\\r?\\n  return it;\\r?\\nend', E'
  -- 44. 0435 — Banco: o Postgres reiniciou nas últimas 24 h? (em série = falta de memória — 27/11/2026: 8 vezes numa tarde)
  select count(*)::int, string_agg(to_char(r.subiu_em at time zone ''America/Sao_Paulo'', ''DD/MM HH24:MI''), '', '' order by r.subiu_em) into n, ex
    from public.banco_reinicios r
   where r.subiu_em > now() - interval ''24 hours'';
  it := it || jsonb_build_object(''codigo'', ''banco_reinicio'', ''nome'', ''Banco: o Postgres não reiniciou nas últimas 24 h'',
    ''nivel'', case when n = 0 then ''ok'' when n = 1 then ''atencao'' else ''falha'' end, ''n'', n,
    ''texto'', case when n = 0 then ''nenhum reinício do banco nas últimas 24 h''
                    else format(''o banco reiniciou %s vez(es) nas últimas 24 h: %s — em cada uma as telas dão "Failed to fetch" e a Mari pode deixar lead sem resposta'', n, left(ex, 300)) end,
    ''fazer'', case when n = 0 then null
                    when n = 1 then ''Avisar o Claude Code: ver o motivo no log do Postgres (um reinício isolado pode ser manutenção da Supabase).''
                    else ''Avisar o Claude Code e o Ricardo: reinício em série é falta de memória — ver INFRA › Desempenho e decidir o upgrade da máquina.'' end);

  return it;
end');
  execute d;
end $$;

-- 5. Agenda: a cada 2 min (a cópia local do portão não tem pg_cron: lá o agendamento é pulado) ------------------------------------
do $agenda$
begin
  if not exists (select 1 from pg_namespace where nspname = 'cron') then
    raise notice '0435: sem pg_cron (cópia local) — agendamento pulado';
    return;
  end if;
  execute $x$select cron.unschedule('banco_reinicio') where exists (select 1 from cron.job where jobname = 'banco_reinicio')$x$;
  execute $x$select cron.schedule('banco_reinicio', '*/2 * * * *', $cron$select public.banco_reinicio_registrar();$cron$)$x$;
end $agenda$;

-- 6. Conferência final ----------------------------------------------------------------------------------------------------------
do $$
begin
  perform public.banco_reinicio_registrar();        -- anota o início de agora, se faltar
  if not exists (select 1 from public.banco_reinicios where subiu_em = date_trunc('second', pg_postmaster_start_time())) then
    raise exception '0435: o início atual do Postgres não ficou anotado';
  end if;
end $$;

commit;
