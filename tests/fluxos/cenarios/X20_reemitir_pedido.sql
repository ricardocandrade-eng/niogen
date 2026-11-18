-- id: X20
-- titulo: Cliente troca a forma de pagamento: a OS é cancelada e o pedido reemitido — só o admin grava a OS nova; a biometria fica
-- tipo: atual
select sim.venda_pronta('Rita X20') as c \gset
select sim.como('backoffice');
select public.backoffice_momento(sim.venda(:'c'), 'os_agendar', jsonb_build_object('os', '86' || sim._conv(:'c'), 'dia', (current_date + 3)::text, 'periodo', '13:00', 'forma', 'cartao'));
select sim.fila_rodar();
select sim.confere('venda agendada com a OS antiga', (select status = '2_aguardando_instalacao' and forma_pagamento = 'cartao' from public.vendas where id = sim.venda(:'c')), '');

-- o backoffice tenta gravar a OS nova: só o admin corrige a OS depois de gravada (0275)
select sim.como('backoffice');
select coalesce(sim.recusa(format($q$select public.backoffice_momento(%L::uuid, 'os', jsonb_build_object('os', %L, 'forma', 'boleto'))$q$, sim.venda(:'c'), '87' || sim._conv(:'c'))), '') as rec \gset
select sim.confere('backoffice não reemite (só o admin)', :'rec' ilike '%admin%', :'rec');

-- o admin reemite: OS nova, boleto, agenda velha apagada, biometria mantida
select sim.como('admin');
select public.backoffice_momento(sim.venda(:'c'), 'os', jsonb_build_object('os', '87' || sim._conv(:'c'), 'forma', 'boleto', 'motivo', 'cliente trocou a forma de pagamento'));
select sim.fila_rodar();
select sim.confere('a venda tem a OS nova e o boleto',
  (select nio_os = '87' || sim._conv(:'c') and nio_pedido = nio_os and forma_pagamento = 'boleto' from public.vendas where id = sim.venda(:'c')), '');
select sim.confere('a agenda velha saiu e a venda volta para "falta agendar"',
  (select status = '1_vendido' and instalacao_agendada_para is null from public.vendas where id = sim.venda(:'c')), '');
select sim.confere('a biometria aprovada continua valendo',
  (select biometria_status = 'validada' from public.vendas where id = sim.venda(:'c')), '');
select sim.confere('o histórico guarda a OS antiga',
  exists (select 1 from public.eventos_venda e where e.venda_id = sim.venda(:'c') and e.tipo = 'os_reemitida'
           and e.detalhe ->> 'os_antiga' = '86' || sim._conv(:'c') and e.detalhe ->> 'forma_antiga' = 'cartao'), '');

-- gravar de novo a mesma OS não faz nada (recusa) — 0298: com o motivo, a recusa é a do passo
select coalesce(sim.recusa(format($q$select public.backoffice_momento(%L::uuid, 'os', jsonb_build_object('os', %L, 'motivo', 'teste do X20: mesma OS'))$q$, sim.venda(:'c'), '87' || sim._conv(:'c'))), '') as rec2 \gset
select sim.confere('a mesma OS de novo é recusada', :'rec2' ilike '%já foi gravada%', :'rec2');

-- a agenda nova chega e a venda segue
select sim.como('backoffice');
select public.backoffice_momento(sim.venda(:'c'), 'agendar', jsonb_build_object('dia', (current_date + 5)::text, 'periodo', '08:00'));
select sim.fila_rodar();
select sim.confere('agenda nova gravada', (select status = '2_aguardando_instalacao' and instalacao_agendada_para is not null from public.vendas where id = sim.venda(:'c')), '');
select sim.como('servico');
