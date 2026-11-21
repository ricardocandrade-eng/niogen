-- id: X64
-- titulo: 0338 (20/11): o time escreve, o cliente some, o prazo de 1 h fecha a conversa e a janela de 24 h devolve o lead para a Mari — o projetor em sombra não acha a ordem do Devolver contrária nem reclama da conversa fechada
-- tipo: atual
-- Caso: Chatwoot 42, 172, 176, 179 e 180 (19–20/11): "contrária" no desatribuir do Devolver e "falta resolver" com a Mari atendendo.
select sim.lead_novo('Davi X64') as c \gset
select sim.mari_fala(:'c', 'Oi! Sou a Mari, da Dharma. Qual o seu CEP?');
select sim.como('backoffice');
select public.backoffice_momento(null, 'assumir', jsonb_build_object('conversa_id', :'c'));
select sim.fila_rodar();
select sim.como('backoffice');
select public.backoffice_responder(:'c', 'Oi! Conseguiu ver os planos que te mandei?');
select sim.fila_rodar();
select sim.como('servico');
select sim.confere('o time assumiu e falou por último', (sim.foto(:'c') ->> 'humano')::boolean and sim.cw_de(:'c') ->> 'agente' is not null, sim.foto(:'c')::text);

-- 2 h: o prazo de 1 h (C10) fecha a conversa com o dono guardado
select sim.espera(:'c', '2 hours');
select sim.tique();
select sim.confere('o prazo de 1 h fechou a conversa', sim.cw_de(:'c') ->> 'status' in ('resolved', 'snoozed'), sim.cw_de(:'c')::text);

-- 25 h: a janela fechou — volta para a Mari
select sim.passa(:'c', '24 hours');
select max(id) as corte from public.projetor_sombra \gset
select public._conversas_volta_mari();
select sim.fila_rodar();
select sim.confere('janela fechada: voltou para a Mari, sem dono no Chatwoot',
  not (sim.foto(:'c') ->> 'humano')::boolean and sim.cw_de(:'c') ->> 'agente' is null and sim.cw_de(:'c') ->> 'time' is null, sim.foto(:'c')::text);
select coalesce((select situacao from public.v_lead_situacao where conversa_id = :'c'), '') as s1 \gset
select sim.confere('a situação é Mari atendendo', :'s1' = 'mari_atendendo', :'s1');
select coalesce((select string_agg(momento || ':' || tipo || ':' || veredito || ' (' || coalesce(motivo, '') || ')', ' | ')
  from public.projetor_sombra where conversa_id = :'c' and id > :corte and veredito in ('contraria', 'falta', 'erro')), '') as ruim \gset
select sim.confere('o projetor em sombra não acha nada contrário nem faltando no Devolver', :'ruim' = '', :'ruim');
select coalesce((select string_agg(distinct situacao, ',') from public.projetor_sombra where conversa_id = :'c' and id > :corte
  and momento in ('devolver_mari', 'volta_mari')), '') as sj \gset
select sim.confere('o Devolver é julgado pela situação de destino', :'sj' = 'mari_atendendo', :'sj');

-- o cliente escreve: a conversa reabre e a Mari atende (o juiz volta a pedir aberta)
select sim.cliente_escreve(:'c', 'oi, voltei! ainda dá para ver?') as r \gset
select sim.fila_rodar();
select sim.confere('o cliente voltou: a Mari respondeu', :'r' = 'respondeu', :'r');
