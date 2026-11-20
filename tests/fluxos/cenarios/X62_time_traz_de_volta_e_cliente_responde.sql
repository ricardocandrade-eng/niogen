-- id: X62
-- titulo: 0335 (20/11): o time escreve a um lead na Saída "Sem resposta" e o cliente responde → o lead fica em andamento com o time (responder agora); passadas 25 h, não volta à Saída
-- tipo: atual
select sim.lead_novo('Vera X59') as c \gset
select sim.cliente_escreve(:'c', 'oi, tem internet no meu bairro?');
select sim.como('backoffice');
select public.lead_sair(:'c', null, 'sem_resposta');
select sim.fila_rodar();
select sim.passa(:'c', '2 hours');
select sim.como('backoffice');
select public.backoffice_responder(:'c', 'Oi, Vera! Ainda tem interesse na internet da Nio?');
select sim.fila_rodar();
select sim.como('servico');
select sim.confere('o lead voltou', sim.lead_de(:'c') ->> 'destino' = 'em_andamento', sim.lead_de(:'c')::text);
select sim.passa(:'c', '30 minutes');
select sim.cliente_escreve(:'c', 'tenho sim, qual o valor?') as r \gset
select sim.fila_rodar();
select sim.confere('a Mari não respondeu no lugar do time', :'r' like 'calada%', :'r');
select coalesce((select situacao from public.v_lead_situacao where conversa_id = :'c'), '') as s1 \gset
select sim.confere('o cliente respondeu: responder agora', :'s1' = 'time_agora', :'s1');
select sim.espera(:'c', '25 hours');
select sim.confere('não voltou à Saída', sim.lead_de(:'c') ->> 'destino' = 'em_andamento', sim.lead_de(:'c')::text);
select sim.confere('a marca da volta saiu', (select volta_time_em is null from public.mari_conversas where id = :'c'), '');
