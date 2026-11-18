-- id: X30
-- titulo: Fase 2, passo 3 (0295): a tela não grava a etapa da venda direto — o UPDATE em vendas.status de quem está logado é recusado; os botões (porta) e o Mover do admin seguem valendo
-- tipo: atual
-- Até a 0295 o "Mover para" do admin no caminho natural fazia um PATCH em vendas.status (regra de ouro 2: a tela nunca grava estado).
select sim.venda_pronta('Rui X30') as c \gset
select sim.como('backoffice');
select public.backoffice_momento(sim.venda(:'c'), 'os_agendar', jsonb_build_object('os', '83' || sim._conv(:'c'), 'dia', (current_date + 2)::text, 'periodo', '08:00', 'forma', 'boleto'));
select sim.fila_rodar();
select sim.confere('o botão da ficha (porta) anda a etapa: aguardando instalação',
  sim.foto(:'c') -> 'venda' ->> 'status' = '2_aguardando_instalacao', (sim.foto(:'c') -> 'venda' ->> 'status'));
-- o PATCH da tela: o comando de topo é o próprio UPDATE em vendas (como o PostgREST manda)
select sim.como('admin');
select sim.venda(:'c') as v \gset
\set ON_ERROR_STOP 0
update public.vendas set status = '3_instalado' where id = :'v';
\set ON_ERROR_STOP 1
select sim.confere('o UPDATE direto da etapa, logado, é recusado (a venda não andou)',
  (select status from public.vendas where id = :'v') = '2_aguardando_instalacao',
  (select status from public.vendas where id = :'v'));
-- outros campos a tela continua gravando (complemento, referência…)
update public.vendas set ponto_referencia = 'perto da praça' where id = :'v';
select sim.confere('campo que não é a etapa: a tela grava normalmente',
  (select ponto_referencia from public.vendas where id = :'v') = 'perto da praça', 'não gravou');
-- o Mover do admin (porta, com motivo) anda a etapa
select public.venda_mover_admin(:'v', '3_instalado', 'teste do X30: instalada confirmada com a Nio')::text as r \gset
select sim.fila_rodar();
select sim.confere('o Mover do admin pela porta vale (instalada, com o motivo)',
  (select status from public.vendas where id = :'v') = '3_instalado', :'r');
