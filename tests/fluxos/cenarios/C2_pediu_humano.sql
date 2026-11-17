-- id: C2
-- titulo: Cliente pede humano: vai para o time e a Mari se cala
-- tipo: atual
select sim.lead_novo('Gil C2') as c \gset
select sim.mari_handoff(:'c', 'pedido_humano');
select sim.fila_rodar();
select sim.cliente_escreve(:'c', 'alguém pode me atender?') as r \gset
select sim.confere('a Mari ficou calada', :'r' like 'calada%', :'r');
select sim.confere('a vez é do time', sim.lead_de(:'c') ->> 'vez' = 'time', sim.lead_de(:'c')::text);
select sim.confere('o time tem prazo para responder', sim.lead_de(:'c') ->> 'prazo' is not null, sim.lead_de(:'c')::text);
