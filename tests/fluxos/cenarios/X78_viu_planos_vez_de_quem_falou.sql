-- id: X78
-- titulo: 0352 (caso L-233, 22/11): lead que viu os planos, com o time dono — o cliente escreve → "responder agora" (antes ficava "esperando o cliente"); o time responde → "esperando o cliente" com o prazo da cutucada; 3 h calado → "Cutucar o cliente"
-- tipo: atual
select sim.como('servico');
insert into public.config_regras (chave, valor, descricao) values
  ('time_horario', '{"1": [0, 24], "2": [0, 24], "3": [0, 24], "4": [0, 24], "5": [0, 24], "6": [0, 24], "7": [0, 24]}'::jsonb, 'X78: time aberto o dia todo')
on conflict (chave) do update set valor = excluded.valor;
select sim.lead_novo('Lurdes X78') as c \gset
select sim.mari_fala(:'c', 'Temos o Essencial por R$ 140 no boleto. Qual prefere?');
update public.mari_conversas set funil_etapa = 'viu_planos' where id = :'c';
select sim.como('backoffice');
select public.backoffice_conversa(:'c', 'atribuir', 'eu');
select sim.fila_rodar();
select sim.como('servico');
select coalesce((select status from public.v_leads where conversa_id = :'c'), '') as st \gset
select sim.confere('premissa: o lead está em "viu_planos"', :'st' = 'viu_planos', :'st');
select sim.cliente_escreve(:'c', 'só fecho se souber a data da instalação', false) as r \gset
select sim.fila_rodar();
select coalesce((select situacao from public.v_lead_situacao where conversa_id = :'c'), '') as s1 \gset
select sim.confere('o cliente escreveu, com o time dono: responder agora', :'s1' = 'time_agora', :'s1');
select sim.como('backoffice');
select public.backoffice_responder(:'c', 'Consigo agendar para segunda-feira. Me passa o seu CPF?');
select sim.fila_rodar();
select sim.como('servico');
select coalesce((select situacao from public.v_lead_situacao where conversa_id = :'c'), '') as s2 \gset
select sim.confere('o time respondeu: esperando o cliente', :'s2' = 'time_esperando', :'s2');
select sim.confere('com o prazo da cutucada (~3 h) gravado',
  (select prazo_em from public.lead_estado where conversa_id = :'c') between now() + interval '2 hours 50 minutes' and now() + interval '3 hours 5 minutes',
  (select coalesce(prazo_em::text, 'vazio') from public.lead_estado where conversa_id = :'c'));
select sim.espera(:'c', '3 hours 10 minutes');
select coalesce((select situacao from public.v_lead_situacao where conversa_id = :'c'), '') as s3 \gset
select sim.confere('3 h calado: a vez volta ao time (cutucar)', :'s3' = 'time_agora', :'s3');
select sim.como('backoffice');
select coalesce((select x ->> 'o_que_fazer' from jsonb_array_elements(public.live_situacoes()) x where x ->> 'conversa_id' = :'c'), '') as t \gset
select sim.confere('a Live diz "Cutucar o cliente"', :'t' like 'Cutucar o cliente%', :'t');
