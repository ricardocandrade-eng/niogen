-- id: X124
-- titulo: 0393 (caso L-153; Ricardo, 25/11: "não existe essa regra de viabilidade vencer com 7 dias"): viabilidade Viável do portal registrada há 30 dias continua valendo — a venda segue marcada como viável, a jornada não pede "consultar de novo" e a trava de virar venda não recusa por causa dela
-- tipo: atual
select sim.lead_com_venda('Vera X124') as c \gset
select sim.como('backoffice');
select public.backoffice_momento(sim.venda(:'c'), 'assumir');
select sim.fila_rodar();
-- 30 dias depois (todas as datas do lead voltam 30 dias, inclusive a da viabilidade)
select sim.como('servico');
select sim.passa(:'c', '30 days');
select sim.confere('a viabilidade tem mesmo mais de 7 dias',
  (select nio_viab_resultado = 'viavel' and nio_viab_em < now() - interval '29 days' from public.vendas where id = sim.venda(:'c')),
  (select nio_viab_resultado || ' · ' || nio_viab_em::text from public.vendas where id = sim.venda(:'c')));
select sim.como('backoffice');
select sim.confere('v_vendas: viabilidade do portal continua ok',
  (select nio_viab_ok from public.v_vendas where id = sim.venda(:'c')), 'nio_viab_ok = false');
select coalesce((select o_que_fazer || ' | ' || botao from public.v_jornada where venda_id = sim.venda(:'c') limit 1), '') as j1 \gset
select sim.confere('a jornada não fala em viabilidade vencida nem manda consultar de novo',
  :'j1' not ilike '%vencida%' and :'j1' not ilike '%consultar a viabilidade%' and :'j1' not like '%| viabilidade', :'j1');
-- a venda anda até a OS sem que a trava reclame da viabilidade
select coalesce(public.backoffice_momento(sim.venda(:'c'), 'credito', '{"resultado":"aprovado"}')::text, '') as av \gset
select sim.confere('gravar o crédito não devolve o aviso "Registre a viabilidade"', :'av' not ilike '%Registre a viabilidade%', left(:'av', 300));
select public.backoffice_momento(sim.venda(:'c'), 'biometria', '{"resultado":"validada"}');
select sim.fila_rodar();
select sim.como('backoffice');
select coalesce(sim.recusa(format($q$select public.backoffice_momento(%L, 'os_agendar', %L::jsonb)$q$, sim.venda(:'c'),
  jsonb_build_object('os', '97' || sim._conv(:'c'), 'dia', (current_date + 4)::text, 'periodo', '08:00', 'forma', 'boleto')::text)), '') as rec \gset
select sim.confere('gravar a OS (virar venda) não é recusado', :'rec' = '', :'rec');
select sim.confere('e a venda saiu de Qualificado',
  (select status <> '0_qualificado' from public.vendas where id = sim.venda(:'c')), (select status from public.vendas where id = sim.venda(:'c')));
