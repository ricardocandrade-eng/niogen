-- id: C8
-- titulo: Time devolve para a Mari e ela volta de verdade
-- tipo: atual
select sim.lead_com_venda('Lia C8') as c \gset
select sim.como('backoffice');
select public.backoffice_momento(sim.venda(:'c'), 'assumir');
select sim.fila_rodar();
select public.backoffice_momento(sim.venda(:'c'), 'devolver_mari');
select sim.fila_rodar();
select sim.confere('sem dono e sem time depois de devolver', sim.cw_de(:'c') ->> 'agente' is null and sim.cw_de(:'c') ->> 'time' is null, sim.cw_de(:'c')::text);
select sim.cliente_escreve(:'c', 'oi, e agora?') as r \gset
select sim.fila_rodar();
select sim.confere('a Mari respondeu', :'r' = 'respondeu', :'r');
select sim.confere('o time não voltou sozinho depois da mensagem do cliente', sim.cw_de(:'c') ->> 'time' is null, sim.cw_de(:'c')::text);
-- Decisão do Ricardo (17/11): "vez" é de quem tem a próxima tarefa. Devolver passa só a CONVERSA para a Mari; rodar o
-- crédito continua sendo do time, então a escada segue cobrando o time.
select sim.confere('a conversa é da Mari: sem dono no NIOGEN', not (sim.foto(:'c') ->> 'humano')::boolean
  and not (sim.foto(:'c') ->> 'time')::boolean, sim.foto(:'c')::text);
select sim.confere('a tarefa da venda (rodar crédito) segue com o time, com prazo',
  sim.lead_de(:'c') ->> 'vez' = 'time' and sim.lead_de(:'c') ->> 'status' = 'rodar_credito' and sim.lead_de(:'c') ->> 'prazo' is not null,
  sim.lead_de(:'c')::text);
