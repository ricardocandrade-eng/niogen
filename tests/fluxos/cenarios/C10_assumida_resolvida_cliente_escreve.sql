-- id: C10
-- titulo: Com o time, esperando o cliente: fecha sozinha, ele escreve e volta para o mesmo dono
-- tipo: regra_nova
select sim.lead_com_venda('Marcos C10') as c \gset
select sim.como('backoffice');
select public.backoffice_momento(sim.venda(:'c'), 'assumir');
select sim.fila_rodar();
select public.backoffice_responder(:'c', 'Te mandei o link, me avisa quando fizer.');
select sim.fila_rodar();
select sim.espera(:'c', '2 hours');
select sim.confere('vez do cliente: a conversa fechou sozinha, com o dono guardado', sim.cw_de(:'c') ->> 'status' = 'resolved', sim.cw_de(:'c')::text);
select sim.cliente_escreve(:'c', 'fiz!') as r \gset
select sim.fila_rodar();
select sim.confere('a conversa reabriu', sim.cw_de(:'c') ->> 'status' = 'open', sim.cw_de(:'c')::text);
select sim.confere('a Mari não respondeu no lugar do time', :'r' like 'calada%', :'r');
select sim.confere('a vez voltou para o time', sim.lead_de(:'c') ->> 'vez' = 'time', sim.lead_de(:'c')::text);
select sim.confere('o dono continua o mesmo', sim.cw_de(:'c') ->> 'agente' is not null, sim.cw_de(:'c')::text);
