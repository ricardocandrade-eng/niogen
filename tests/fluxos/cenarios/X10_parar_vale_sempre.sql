-- id: X10
-- titulo: "Cliente pediu para parar" vale em qualquer situação — inclusive Instalada (regra de ouro 6, 0270)
-- tipo: atual
select sim.venda_pronta('Rui X10') as c \gset
select sim.como('backoffice');
select public.backoffice_momento(sim.venda(:'c'), 'os_agendar', jsonb_build_object('os', '88' || sim._conv(:'c'), 'dia', (current_date + 2)::text, 'periodo', '08:00', 'forma', 'boleto'));
select sim.fila_rodar();
select sim.passa(:'c', '2 days');
select sim.instalou(:'c');
select sim.fila_rodar();
select sim.como('backoffice');
select public.porta_botoes(:'c', sim.venda(:'c')) as b \gset
select sim.confere('Instalada: o botão "pediu para parar" aparece', (:'b'::jsonb #>> '{eventos,momento:parar,ok}')::boolean, :'b'::jsonb #>> '{eventos,momento:parar}');
select coalesce(sim.recusa(format($q$select public.backoffice_momento(%L, 'parar')$q$, sim.venda(:'c'))), '') as rec \gset
select sim.confere('Instalada: a porta aceita o pedido de parar', :'rec' = '', :'rec');
select sim.fila_rodar();
select sim.confere('a conversa fica marcada como Não contatar', (select nao_contatar from public.mari_conversas where id = :'c'), null);
