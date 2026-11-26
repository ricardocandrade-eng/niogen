-- id: X136
-- titulo: 0407 (Ricardo 25/11: "vamos fazer pelo menos a de FPD junto"): faturas em aberto do Dashboard entram por faturas_importar — arquivo vazio só vale quando os cartões dizem 0 em aberto (download falho não apaga o retrato), a fatura casa com a venda pelo nº da OS, aparece na ficha_venda, a rodada fica registrada e a conferência ganha o item do Dashboard
-- tipo: atual
select sim.como('servico');

-- uma venda com OS para casar a fatura
select id as v, btrim(nio_pedido) as os from public.vendas where coalesce(btrim(nio_pedido), '') <> '' order by criado_em desc limit 1 \gset

-- 1ª leitura: uma fatura vencida dessa OS e uma de OS que o NIOGEN não conhece
select public.faturas_importar('teste X136', jsonb_build_array(
  jsonb_build_object('nr_ordem', :'os', 'nr_fatura', 'FX136', 'indicador', 'FPD', 'dt_vencimento', '2026-11-10',
                     'dias_atraso', 12, 'faixa', '0 a 15 Dias', 'status_pgto', 'Em aberto', 'bruto', jsonb_build_object('NR ORDEM', :'os')),
  jsonb_build_object('nr_ordem', '99X136', 'nr_fatura', 'FX136b', 'indicador', 'SPD', 'dias_atraso', 0)),
  '{"FPD": {"pagas": 3, "a_vencer": 1, "vencidas": 1}}'::jsonb) as r1 \gset
select sim.confere('as duas linhas entram e só a da OS conhecida casa com a venda',
  (:'r1'::jsonb ->> 'linhas')::int = 2 and (:'r1'::jsonb ->> 'casaram')::int = 1 and (:'r1'::jsonb -> 'sem_venda') ? '99X136', :'r1');
select sim.confere('a fatura casada aponta para a venda', exists (select 1 from public.nio_faturas_abertas where nr_fatura = 'FX136' and venda_id = :'v'), '');

-- download vazio com cartão dizendo que há fatura em aberto: recusa e o retrato fica
select sim.confere('arquivo vazio com cartão > 0 é recusado',
  sim.recusa($q$select public.faturas_importar('vazio', '[]'::jsonb, '{"FPD": {"a_vencer": 0, "vencidas": 2}}'::jsonb)$q$) is not null, '');
select sim.confere('arquivo vazio sem cartões é recusado', sim.recusa($q$select public.faturas_importar('vazio', '[]'::jsonb, null)$q$) is not null, '');
select sim.confere('o retrato anterior continua lá', (select count(*) from public.nio_faturas_abertas) = 2, (select count(*)::text from public.nio_faturas_abertas));

-- a ficha da venda traz a fatura (mesma chamada)
select sim.como('admin');
select sim.confere('ficha_venda traz as faturas em aberto',
  (public.ficha_venda(:'v') -> 'faturas' -> 0 ->> 'nr_fatura') = 'FX136', left(coalesce(public.ficha_venda(:'v') ->> 'faturas', 'null'), 200));

-- tudo pago: arquivo vazio + cartões zerados troca o retrato por nada
select sim.como('servico');
select public.faturas_importar('tudo pago', '[]'::jsonb, '{"FPD": {"pagas": 5, "a_vencer": 0, "vencidas": 0}}'::jsonb) as r2 \gset
select sim.confere('vazio com cartões zerados vale: retrato vazio', (select count(*) from public.nio_faturas_abertas) = 0, :'r2');

-- a rodada e o mapa ficam registrados; a conferência tem o item
select public.dashboard_rodada_registrar(jsonb_build_object('ok', true, 'origem', 'teste', 'resumo', '{"osab": {"linhas": 7}}'::jsonb,
  'mapa', jsonb_build_array(jsonb_build_object('aba', 'Geral', 'visuais', '[{"titulo": "Funil de Vendas"}]'::jsonb)))) as r3 \gset
select sim.confere('rodada registrada', exists (select 1 from public.dashboard_rodadas where id = (:'r3'::jsonb ->> 'rodada')::bigint and ok), :'r3');
select sim.confere('mapa da aba Geral gravado', exists (select 1 from public.dashboard_mapa where aba = 'Geral'), '');
select sim.confere('dashboard_config devolve as 9 abas', jsonb_array_length(public.dashboard_config() -> 'abas') = 9, left((public.dashboard_config())::text, 200));
select sim.confere('conferência tem o item do Dashboard',
  exists (select 1 from jsonb_array_elements(public.conferencia_itens()) i where i ->> 'codigo' = 'dashboard_rotina'), '');
