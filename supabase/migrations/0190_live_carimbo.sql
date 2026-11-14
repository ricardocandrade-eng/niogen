-- NIOGEN | supabase/migrations/0190_live_carimbo.sql | 14/11/2026 — Claude Code (Opus 5.5)
-- Ricardo, 14/11 ("sistema muito lento de novo" → "Sim, cortar carga"). O Supabase Nio (plano Free, ~430 MB de RAM) engasga
-- com a leitura que as telas repetem por timer: a Live refaz jornada_live (~1,3 s de banco), oportunidades_abertas (~1 s),
-- parceiro_oportunidades_abertas (~0,7 s), live_conferir (~1 s), v_leads e v_andamento_pendencias a cada 60 s, mesmo
-- quando nada foi gravado. Medido em 14/11: em 100 s sem atendimento nenhuma das 86 tabelas de public mudou.
-- O que muda: RPC live_carimbo() — um número que só muda quando alguma tabela que as telas leem foi gravada (soma dos
-- contadores de insert/update/delete que o próprio Postgres mantém em pg_stat_user_tables; não lê tabela, ~1 ms, sem gatilho).
-- O front chama a cada tick e só refaz a carga pesada se o número mudou (ou passou o teto de tempo, por causa dos prazos
-- que vencem com o relógio). Ficam de fora as tabelas que mudam sem ninguém mexer ou que a própria leitura grava:
-- *_log (oportunidades_log, parceiro_oportunidades_log…), mari_erros (furo da jornada), pulso_*, meta_ads_*, mari_portao_rodadas.
-- O número não é dado: zera se o banco reiniciar (o front compara igualdade, então só provoca uma recarga). Só aditivo.
-- Regra 20: não cria estado, tabela nem número de operação — não precisa de conferência.

create or replace function public.live_carimbo()
returns bigint
language sql stable security definer set search_path = public, pg_catalog as $$
  select coalesce(sum(s.n_tup_ins + s.n_tup_upd + s.n_tup_del), 0)::bigint
  from pg_catalog.pg_stat_user_tables s
  where s.schemaname = 'public'
    and s.relname not like '%\_log'
    and s.relname not like 'pulso\_%'
    and s.relname not like 'meta\_ads\_%'
    and s.relname not in ('mari_erros', 'mari_portao_rodadas');
$$;
revoke all on function public.live_carimbo() from public, anon;
grant execute on function public.live_carimbo() to authenticated;

comment on function public.live_carimbo() is
  '0190: muda só quando alguma tabela lida pelas telas foi gravada; o front pula o refresh pesado se não mudou.';
