-- id: X41
-- titulo: Achado da sombra do projetor (19/11): o time é dono e falou por último → a vez é do cliente (situação 3, "esperando o cliente"); o "fechar em 1 h" e a situação concordam; o cliente escreve → vez do time
-- tipo: atual
select sim.lead_novo('Talita X41') as c \gset
select sim.mari_fala(:'c', 'Oi! Sou a Mari, da Dharma. Qual o seu CEP?');
select sim.como('backoffice');
select public.backoffice_conversa(:'c', 'atribuir', 'eu');
select sim.fila_rodar();
select sim.como('backoffice');
select public.backoffice_responder(:'c', 'Bom dia, Talita! Vamos dar continuidade?');
select sim.fila_rodar();
select sim.como('servico');
select coalesce((select situacao from public.v_lead_situacao where conversa_id = :'c'), '') as s1 \gset
select sim.confere('o time falou por último, com dono: a vez é do cliente (esperando o cliente)', :'s1' = 'time_esperando', :'s1');
select sim.espera(:'c', '2 hours');
select sim.confere('1 h sem resposta: conversa resolvida no Chatwoot, dono guardado',
  sim.cw_de(:'c') ->> 'status' = 'resolved' and sim.cw_de(:'c') ->> 'agente' is not null, sim.cw_de(:'c')::text);
select coalesce((select situacao from public.v_lead_situacao where conversa_id = :'c'), '') as s2 \gset
select sim.confere('depois de fechar, segue "esperando o cliente"', :'s2' = 'time_esperando', :'s2');
select sim.confere('o projetor em sombra não vê contradição nesta conversa',
  not exists (select 1 from public.projetor_sombra p where p.conversa_id = :'c' and p.veredito in ('contraria', 'falta')),
  (select string_agg(veredito || ': ' || coalesce(motivo, ''), ' | ') from public.projetor_sombra p where p.conversa_id = :'c' and p.veredito in ('contraria', 'falta')));
select sim.cliente_escreve(:'c', 'oi, pode sim') as r \gset
select sim.fila_rodar();
select coalesce((select situacao from public.v_lead_situacao where conversa_id = :'c'), '') as s3 \gset
select sim.confere('o cliente escreveu: a vez volta ao time (responder agora)', :'s3' = 'time_agora', :'s3');
