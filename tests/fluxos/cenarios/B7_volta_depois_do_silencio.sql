-- id: B7
-- titulo: Cliente volta a escrever depois da Saída por silêncio
-- tipo: atual
select sim.lead_novo('Eva B7') as c \gset
select sim.silencio(:'c', 24);
select sim.cliente_escreve(:'c', 'oi, ainda tem o plano?') as r \gset
select sim.fila_rodar();
select sim.confere('a Mari respondeu', :'r' = 'respondeu', :'r');
select sim.confere('o lead voltou para em andamento', sim.lead_de(:'c') ->> 'destino' = 'em_andamento', sim.lead_de(:'c')::text);
select sim.confere('a conversa está aberta', sim.cw_de(:'c') ->> 'status' = 'open', sim.cw_de(:'c')::text);
