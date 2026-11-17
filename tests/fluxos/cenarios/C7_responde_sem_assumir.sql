-- id: C7
-- titulo: Quem responde vira dono
-- tipo: regra_nova
select sim.lead_novo('Katia C7') as c \gset
select sim.como('backoffice');
select public.backoffice_responder(:'c', 'Olá! Aqui é do time da Dharma, posso te ajudar?');
select sim.fila_rodar();
select sim.confere('a mensagem do time saiu', exists (select 1 from sim.envios where conversa = :'c' and por = 'time'));
select sim.confere('quem respondeu virou dono da conversa', sim.cw_de(:'c') ->> 'agente' is not null, sim.cw_de(:'c')::text);
select sim.cliente_escreve(:'c', 'pode sim') as r \gset
select sim.confere('a Mari não responde por cima do time', :'r' like 'calada%', :'r');
