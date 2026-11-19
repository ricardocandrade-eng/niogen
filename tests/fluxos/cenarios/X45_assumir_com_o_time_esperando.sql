-- id: X45
-- titulo: Divergência 935 (19/11, Chatwoot 137): o time falou por último, a conversa voltou para a Mari sem dono e o time Assume → "Com o time · esperando o cliente" (0310) e a porta concorda
-- tipo: atual
select sim.lead_novo('Gil X45') as c \gset
select sim.mari_fala(:'c', 'Oi! Sou a Mari, da Dharma. Qual o seu CEP?');
select sim.como('backoffice');
select public.backoffice_responder(:'c', 'Oi, Gil! Aqui é do time. Já tem um pedido da Nio no seu nome, procede?');
select sim.fila_rodar();
select sim.como('backoffice');
select public.backoffice_momento(null, 'devolver_mari', jsonb_build_object('conversa_id', :'c'));
select sim.fila_rodar();
select sim.como('servico');
select coalesce((select situacao from public.v_lead_situacao where conversa_id = :'c'), '') as s0 \gset
select sim.confere('sem dono, de volta para a Mari', :'s0' = 'mari_atendendo', :'s0');
select sim.passa(:'c', '15 minutes');   -- o Assumir tem trava contra repetição de 10 min
select sim.como('backoffice');
select public.backoffice_momento(null, 'assumir', jsonb_build_object('conversa_id', :'c'));
select sim.fila_rodar();
select sim.como('servico');
select coalesce((select situacao from public.v_lead_situacao where conversa_id = :'c'), '') as s1 \gset
select sim.confere('Assumir com a última fala do time: esperando o cliente', :'s1' = 'time_esperando', :'s1');
select coalesce((select concorda::text from public.porta_sombra where conversa_id = :'c' and evento = 'momento:assumir' order by id desc limit 1), 'sem anotação') as k \gset
select sim.confere('a porta concorda com o sistema', :'k' = 'true', :'k');
