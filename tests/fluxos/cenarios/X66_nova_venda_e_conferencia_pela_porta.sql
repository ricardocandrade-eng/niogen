-- id: X66
-- titulo: Fase 2, passo 4b (a) (0341): a Nova venda que já nasce em Saída e a conferência do parceiro reprovada passam pela porta — o INSERT direto em Saída de quem está logado é recusado
-- tipo: atual
-- Ricardo, 21/11: "Faz o 4b (a) e (b) enquanto a sombra roda". Até a 0341 a Nova venda gravava status = 'saida' no INSERT e a ficha
-- reprovava a conferência com um PATCH em vendas.status (recusado pela trava da 0295 desde 18/11).

-- (1) Nova venda já em Saída, pelo botão (RPC)
select sim.como('backoffice');
select id as eu from public.usuarios where perfil = 'backoffice' order by id limit 1 \gset
select public.venda_nova_saida(jsonb_build_object('origem', 'indicacao', 'cliente_nome', 'Lia X66', 'cliente_whatsapp', '5532900006601',
  'cep', '36010000', 'numero', '66', 'segmento', 'PF', 'forma_pagamento', 'boleto', 'vendedor_id', :'eu'),
  'ja_cliente_nio', 'cliente ativo', null, null)::text as r \gset
select (:'r'::jsonb ->> 'venda_id') as v1 \gset
select sim.como('servico');
select sim.confere('a Nova venda nasceu em Saída · Já é cliente Nio, com motivo e porquê',
  (select status = 'saida' and saida_motivo = 'ja_cliente_nio' and saida_sub = 'cliente ativo' and motivo_saida like 'Já é cliente Nio%'
     from public.vendas where id = :'v1'), :'r');
select sim.confere('o histórico mostra a criação e a Saída (de Qualificado para Saída)',
  exists (select 1 from public.eventos_venda where venda_id = :'v1' and tipo = 'status' and detalhe ->> 'para' = 'saida'),
  (select string_agg(tipo || ':' || coalesce(detalhe ->> 'status', detalhe ->> 'para', ''), ', ') from public.eventos_venda where venda_id = :'v1'));
select coalesce((select evento || ' · ' || coalesce(concorda::text, 'null') from public.porta_sombra where venda_id = :'v1' order by id desc limit 1), 'sem anotação') as k \gset
select sim.confere('a porta anotou a Saída da venda nova', :'k' like 'saida:ja_cliente_nio%', :'k');

-- (2) o INSERT direto em Saída (como o PostgREST manda), logado, é recusado
select sim.como('backoffice');
\set ON_ERROR_STOP 0
insert into public.vendas (origem, cliente_nome, status, motivo_saida, vendedor_id) values ('indicacao', 'Rui X66', 'saida', 'Já é cliente Nio', :'eu');
\set ON_ERROR_STOP 1
select sim.como('servico');
select sim.confere('o INSERT direto em Saída, logado, é recusado', not exists (select 1 from public.vendas where cliente_nome = 'Rui X66'), 'gravou');
-- criar a venda em Qualificado continua normal
select sim.como('backoffice');
insert into public.vendas (origem, cliente_nome, status, vendedor_id) values ('indicacao', 'Ana X66', '0_qualificado', :'eu');
select sim.como('servico');
select sim.confere('criar a venda em Qualificado segue valendo', exists (select 1 from public.vendas where cliente_nome = 'Ana X66'), 'não gravou');

-- (3) conferência do parceiro reprovada (D17)
select id as par from public.parceiros where status = 'ativo' order by id limit 1 \gset
insert into public.vendas (origem, parceiro_id, cliente_nome, cliente_whatsapp, status, vendedor_id)
values ('parceiro_pap', :'par', 'Bia X66', '5532900006602', '0_qualificado', :'eu') returning id as v2 \gset
select sim.confere('premissa: a venda de parceiro nasce com a conferência pendente',
  (select conferencia_status from public.vendas where id = :'v2') = 'pendente', (select conferencia_status from public.vendas where id = :'v2'));
-- o PATCH antigo da ficha (conferência + etapa) é recusado pela trava da 0295
select sim.como('backoffice');
\set ON_ERROR_STOP 0
update public.vendas set conferencia_status = 'reprovada', conferencia_motivo = 'sem_cobertura', status = 'saida', motivo_saida = 'x' where id = :'v2';
\set ON_ERROR_STOP 1
select public.venda_conferencia_reprovar(:'v2', 'sem_cobertura', 'portal sem fachada')::text as r2 \gset
select sim.como('servico');
select sim.confere('reprovada pela RPC: conferência reprovada e a venda em Saída · Fachada não atendida',
  (select conferencia_status = 'reprovada' and conferencia_motivo = 'sem_cobertura' and status = 'saida' and saida_motivo = 'fachada_nao_atendida'
          and motivo_saida like '%Reprovada na conferência: Sem cobertura%' and conferencia_obs like '%portal sem fachada%'
     from public.vendas where id = :'v2'), :'r2');
select coalesce((select evento from public.porta_sombra where venda_id = :'v2' order by id desc limit 1), 'sem anotação') as k2 \gset
select sim.confere('a porta anotou a Saída da reprovada', :'k2' = 'saida:fachada_nao_atendida', :'k2');
select sim.confere('o evento da conferência ficou no histórico (de pendente para reprovada)',
  exists (select 1 from public.eventos_venda where venda_id = :'v2' and tipo = 'conferencia' and detalhe ->> 'para' = 'reprovada'), 'sem evento');
-- reprovar de novo é recusado; vendedor não reprova
select sim.como('backoffice');
select sim.confere('reprovar uma conferência que não está pendente é recusado',
  sim.recusa(format('select public.venda_conferencia_reprovar(%L, %L)', :'v2', 'outro')) like '%não está pendente%',
  sim.recusa(format('select public.venda_conferencia_reprovar(%L, %L)', :'v2', 'outro')));
select sim.como('vendedor');
select sim.confere('vendedor não reprova a conferência',
  sim.recusa(format('select public.venda_conferencia_reprovar(%L, %L)', :'v2', 'outro')) like '%Só o backoffice ou o admin%',
  sim.recusa(format('select public.venda_conferencia_reprovar(%L, %L)', :'v2', 'outro')));
select sim.como('servico');
