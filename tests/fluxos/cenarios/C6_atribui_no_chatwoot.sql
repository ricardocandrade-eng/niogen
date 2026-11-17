-- id: C6
-- titulo: Atribuir-se direto no Chatwoot vale como Assumir
-- tipo: regra_nova
select sim.lead_novo('Joao C6') as c \gset
select sim.time_no_chatwoot(:'c', '{"agente":"Atendente"}');
select sim.fila_rodar();
select sim.confere('o NIOGEN registrou a pessoa como dona', (sim.foto(:'c') ->> 'humano')::boolean);
select sim.confere('a vez passou para o time', sim.lead_de(:'c') ->> 'vez' = 'time', sim.lead_de(:'c')::text);
select sim.cliente_escreve(:'c', 'oi') as r \gset
select sim.confere('a Mari fica calada', :'r' like 'calada%', :'r');
