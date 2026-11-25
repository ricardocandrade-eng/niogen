-- id: X126
-- titulo: 0395 (Ricardo, 25/11: "Tira a validade de 7 dias do DFV também"): DFV viável consultado há 30 dias continua valendo como pista — dfv_ok segue verdadeiro em v_vendas e v_funil
-- tipo: atual
select sim.lead_com_venda('Dani X126') as c \gset
select sim._servico();
update public.vendas set dfv_viabilidade = 'viavel', dfv_resultado = 'viavel', dfv_consultado_em = now() where id = sim.venda(:'c');
select sim.como('servico');
select sim.passa(:'c', '30 days');
select sim.confere('a consulta do DFV tem mesmo mais de 7 dias',
  (select dfv_viabilidade = 'viavel' and dfv_consultado_em < now() - interval '29 days' from public.vendas where id = sim.venda(:'c')),
  (select coalesce(dfv_viabilidade, '-') || ' · ' || coalesce(dfv_consultado_em::text, '-') from public.vendas where id = sim.venda(:'c')));
select sim.como('backoffice');
select sim.confere('v_vendas: o DFV continua ok', (select dfv_ok from public.v_vendas where id = sim.venda(:'c')), 'dfv_ok = false');
select sim.confere('v_funil: o DFV continua ok', (select bool_and(dfv_ok) from public.v_funil where id = sim.venda(:'c')), 'dfv_ok = false');
