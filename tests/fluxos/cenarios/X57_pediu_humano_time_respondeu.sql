-- id: X57
-- titulo: Chatwoot 184 (19/11): o cliente pediu uma pessoa, o time assumiu e respondeu → a vez é do cliente ("esperando o cliente"), não "responder agora"; o cliente escreve → vez do time
-- tipo: atual
select sim.lead_novo('Nádia X57') as c \gset
select sim.cliente_escreve(:'c', 'quero falar com um atendente');
select sim.mari_handoff(:'c', 'pedido_humano');
select sim.fila_rodar();
select sim.confere('pediu humano: o status é pediu_humano', sim.lead_de(:'c') ->> 'status' = 'pediu_humano', sim.lead_de(:'c')::text);
select coalesce((select situacao from public.v_lead_situacao where conversa_id = :'c'), '') as s0 \gset
select sim.confere('antes de o time falar: responder agora', :'s0' = 'time_agora', :'s0');
select sim.como('backoffice');
select public.backoffice_conversa(:'c', 'atribuir', 'eu');
select sim.fila_rodar();
select sim.como('backoffice');
select public.backoffice_responder(:'c', 'Oi! Sou do time da Dharma, como posso ajudar?');
select sim.fila_rodar();
select sim.como('servico');
select coalesce((select situacao from public.v_lead_situacao where conversa_id = :'c'), '') as s1 \gset
select sim.confere('o time respondeu: esperando o cliente', :'s1' = 'time_esperando', :'s1' || ' · ' || sim.lead_de(:'c')::text);
select sim.cliente_escreve(:'c', 'quero saber do plano de 500') as r \gset
select sim.fila_rodar();
select coalesce((select situacao from public.v_lead_situacao where conversa_id = :'c'), '') as s2 \gset
select sim.confere('o cliente escreveu: responder agora de novo', :'s2' = 'time_agora', :'s2');
