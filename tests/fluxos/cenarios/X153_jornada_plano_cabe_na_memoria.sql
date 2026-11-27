-- id: X153
-- titulo: 0431 (Ricardo, 27/11: "Niogen com muito erro desse: TypeError: Failed to fetch"): o Postgres da produção ficou sem memória e reiniciou 7 vezes numa tarde — só montar o plano da v_jornada gastava 68 MB, porque a view de cima copiava cada coluna da de baixo em cada uso. O plano da v_jornada tem de caber em 40 MB e o da v_jornada_base em 16 MB, e a Live continua devolvendo a jornada
-- tipo: atual

-- 1) a memória que o planejador gasta para montar o plano (EXPLAIN MEMORY, PostgreSQL 17)
create temp table x153_plano (view_nome text, kb int);
do $$
declare v text; j json;
begin
  foreach v in array array['v_jornada', 'v_jornada_base'] loop
    execute 'explain (memory, format json) select * from public.' || v into j;
    insert into x153_plano values (v, (j -> 0 -> 'Planning' ->> 'Memory Used')::int);
  end loop;
end $$;
select sim.confere('o plano da v_jornada cabe em 40 MB (era 68 MB)',
  (select kb < 40000 from x153_plano where view_nome = 'v_jornada'),
  (select kb || ' kB' from x153_plano where view_nome = 'v_jornada'));
select sim.confere('o plano da v_jornada_base cabe em 16 MB (era 20 MB)',
  (select kb < 16000 from x153_plano where view_nome = 'v_jornada_base'),
  (select kb || ' kB' from x153_plano where view_nome = 'v_jornada_base'));

-- 2) a forma que segura isso está nas views (quem reescrever a view sem ela traz os 68 MB de volta)
select sim.confere('a v_jornada lê a base por subconsulta com OFFSET 0',
  pg_get_viewdef('public.v_jornada'::regclass, true) ~ 'FROM v_jornada_base\s+OFFSET 0\)\s+j',
  'sem OFFSET 0');
select sim.confere('a v_jornada_base continua lendo como quem chama (security_invoker)',
  (select coalesce(c.reloptions::text, '') ~ 'security_invoker=true' from pg_class c where c.oid = 'public.v_jornada_base'::regclass),
  (select coalesce(c.reloptions::text, 'sem opções') from pg_class c where c.oid = 'public.v_jornada_base'::regclass));

-- 3) a jornada continua funcionando de ponta a ponta: lead novo com cliente esperando aparece na jornada e na fila
select sim.lead_com_venda('Dora X153') as r \gset
select sim.como('servico');
select sim.cliente_escreve(:'r', 'Oi, tem alguém aí?', false);
select sim.fila_rodar();
select sim.como('backoffice');
select sim.confere('a venda aparece na jornada_live, precisando de ação',
  exists (select 1 from public.jornada_live() j where j.venda_id = sim.venda(:'r') and j.precisa_acao),
  coalesce((select j.o_que_fazer from public.jornada_live() j where j.venda_id = sim.venda(:'r')), 'fora da jornada'));
select public.live2_fila()::text as f \gset
select sim.confere('e na fila da Live 2.0, como Responder',
  exists (select 1 from jsonb_array_elements((:'f')::jsonb -> 'fila') x where x ->> 'venda_id' = sim.venda(:'r')::text and x ->> 'tipo' = 'responder'),
  coalesce((select x ->> 'tipo' from jsonb_array_elements((:'f')::jsonb -> 'fila') x where x ->> 'venda_id' = sim.venda(:'r')::text), 'fora da fila'));
