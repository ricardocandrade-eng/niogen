-- id: H5
-- titulo: O mesmo botão duas vezes não repete mensagem nem nota
-- tipo: atual
-- (sem dono: com o time na conversa o crédito negado não manda mensagem automática — 0224)
select sim.lead_com_venda('Hel H5') as c \gset
select sim.como('backoffice');
select public.backoffice_momento(sim.venda(:'c'), 'devolver_mari');
select sim.fila_rodar();
select public.backoffice_momento(sim.venda(:'c'), 'credito', '{"resultado":"negado"}');
select public.backoffice_momento(sim.venda(:'c'), 'credito', '{"resultado":"negado"}');
select sim.fila_rodar();
select sim.confere('o pedido de outro CPF saiu uma vez só',
  (select count(*) from sim.envios where conversa = :'c' and por <> 'mari') = 1,
  (select count(*) || ' mensagens ao cliente' from sim.envios where conversa = :'c' and por <> 'mari'));
select sim.confere('uma nota só no Chatwoot',
  (select count(*) from public.chatwoot_acoes a where a.conversa_id = :'c' and a.momento = 'credito' and a.tipo = 'nota') = 1,
  (select count(*) || ' notas' from public.chatwoot_acoes a where a.conversa_id = :'c' and a.momento = 'credito' and a.tipo = 'nota'));
