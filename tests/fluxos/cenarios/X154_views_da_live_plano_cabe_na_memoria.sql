-- id: X154
-- titulo: 0432 (Ricardo, 27/11: "Não é melhor já fazer essa correção? Quero postergar ao máximo novas despesas com upgrade"): as seis views que a Live lê não copiam mais as expressões das subconsultas LATERAL — o plano da v_leads tem de caber em 8 MB (era 14,5) e o da v_jornada em 20 MB (era 68 antes da 0431), toda LATERAL termina em OFFSET 0 ou LIMIT, e Leads, jornada, fila e oportunidades continuam respondendo
-- tipo: atual

-- 1) a memória que o planejador gasta para montar o plano (EXPLAIN MEMORY, PostgreSQL 17)
create temp table x154_plano (view_nome text, kb int);
do $$
declare v text; j json;
begin
  foreach v in array array['v_leads', 'v_jornada', 'v_jornada_base'] loop
    execute 'explain (memory, format json) select * from public.' || v into j;
    insert into x154_plano values (v, (j -> 0 -> 'Planning' ->> 'Memory Used')::int);
  end loop;
end $$;
select sim.confere('o plano da v_leads cabe em 8 MB (era 14,5 MB)',
  (select kb < 8000 from x154_plano where view_nome = 'v_leads'), (select kb || ' kB' from x154_plano where view_nome = 'v_leads'));
select sim.confere('o plano da v_jornada cabe em 20 MB (era 68 MB antes da 0431)',
  (select kb < 20000 from x154_plano where view_nome = 'v_jornada'), (select kb || ' kB' from x154_plano where view_nome = 'v_jornada'));
select sim.confere('o plano da v_jornada_base cabe em 11 MB (era 20 MB antes da 0431)',
  (select kb < 11000 from x154_plano where view_nome = 'v_jornada_base'), (select kb || ' kB' from x154_plano where view_nome = 'v_jornada_base'));

-- 2) a forma que segura isso: nenhuma LATERAL das seis views fica sem OFFSET 0 (ou LIMIT) — quem reescrever uma delas sem isso
--    traz a cópia de volta. Conta as LATERAL e as que fecham com OFFSET 0 / LIMIT n.
select sim.confere('toda subconsulta LATERAL das seis views fecha com OFFSET 0 ou LIMIT',
  (select bool_and(n_lateral <= n_fecho) from (
     select v, (select count(*) from regexp_matches(d, 'LATERAL \( SELECT', 'g')) as n_lateral,
               (select count(*) from regexp_matches(d, '(OFFSET 0|LIMIT \d+)\)', 'g')) as n_fecho
       from (select v, pg_get_viewdef(('public.' || v)::regclass, true) as d
               from unnest(array['v_leads', 'v_mari_quadro', 'v_mari_quadro_jornada', 'v_jornada_base', 'v_jornada', 'v_oportunidades']) v) x) y),
  (select string_agg(v || ' ' || n_fecho || '/' || n_lateral, ' · ') from (
     select v, (select count(*) from regexp_matches(d, 'LATERAL \( SELECT', 'g')) as n_lateral,
               (select count(*) from regexp_matches(d, '(OFFSET 0|LIMIT \d+)\)', 'g')) as n_fecho
       from (select v, pg_get_viewdef(('public.' || v)::regclass, true) as d
               from unnest(array['v_leads', 'v_mari_quadro', 'v_mari_quadro_jornada', 'v_jornada_base', 'v_jornada', 'v_oportunidades']) v) x) y));
select sim.confere('as views que leem como quem chama continuam assim (security_invoker)',
  (select count(*) = 5 from pg_class c where c.relnamespace = 'public'::regnamespace
      and c.relname in ('v_leads', 'v_mari_quadro', 'v_mari_quadro_jornada', 'v_jornada_base', 'v_oportunidades')
      and coalesce(c.reloptions::text, '') ~ 'security_invoker=true'),
  (select string_agg(c.relname || ' ' || coalesce(c.reloptions::text, '-'), ' · ') from pg_class c where c.relnamespace = 'public'::regnamespace
      and c.relname in ('v_leads', 'v_mari_quadro', 'v_mari_quadro_jornada', 'v_jornada_base', 'v_oportunidades')));

-- 3) de ponta a ponta: lead novo com cliente esperando aparece em Leads, na jornada e na fila; oportunidades responde
select sim.lead_com_venda('Elisa X154') as r \gset
select sim.como('servico');
select sim.cliente_escreve(:'r', 'Oi, tem alguém aí?', false);
select sim.fila_rodar();
select sim.como('backoffice');
select sim.confere('a venda aparece na v_leads, em andamento',
  exists (select 1 from public.v_leads l where l.venda_id = sim.venda(:'r') and l.destino = 'em_andamento'),
  coalesce((select l.destino || ' · ' || l.etapa from public.v_leads l where l.venda_id = sim.venda(:'r')), 'fora da v_leads'));
select sim.confere('aparece na jornada_live, precisando de ação',
  exists (select 1 from public.jornada_live() j where j.venda_id = sim.venda(:'r') and j.precisa_acao),
  coalesce((select j.o_que_fazer from public.jornada_live() j where j.venda_id = sim.venda(:'r')), 'fora da jornada'));
select public.live2_fila()::text as f \gset
select sim.confere('e na fila da Live 2.0, como Responder',
  exists (select 1 from jsonb_array_elements((:'f')::jsonb -> 'fila') x where x ->> 'venda_id' = sim.venda(:'r')::text and x ->> 'tipo' = 'responder'),
  coalesce((select x ->> 'tipo' from jsonb_array_elements((:'f')::jsonb -> 'fila') x where x ->> 'venda_id' = sim.venda(:'r')::text), 'fora da fila'));
select sim.confere('oportunidades_abertas responde sem erro',
  (select count(*) >= 0 from public.oportunidades_abertas()), 'erro');
