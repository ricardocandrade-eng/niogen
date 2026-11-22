-- id: X77
-- titulo: 0351 (caso L-233, 21/11): a situação gravada acompanha a conversa na hora — o time responde e já fica "esperando o cliente" com o prazo da cutucada; o cliente escreve e já fica "responder agora" (evento cliente_escreveu, não prazo:tempo da varredura)
-- tipo: atual
select sim.como('servico');
insert into public.config_regras (chave, valor, descricao) values
  ('time_horario', '{"1": [0, 24], "2": [0, 24], "3": [0, 24], "4": [0, 24], "5": [0, 24], "6": [0, 24], "7": [0, 24]}'::jsonb, 'X77: time aberto o dia todo')
on conflict (chave) do update set valor = excluded.valor;
select sim.lead_novo('Cida X77') as c \gset
select sim.mari_fala(:'c', 'Oi! Sou a Mari, da Dharma. Qual o seu CEP?');
select sim.como('backoffice');
select public.backoffice_conversa(:'c', 'atribuir', 'eu');
select sim.fila_rodar();
select sim.como('backoffice');
select public.backoffice_responder(:'c', 'Oi, Cida! Me passa o seu CPF?');
select sim.fila_rodar();
select sim.como('servico');
-- sem varredura (sim.tique): só o que a própria fala gravou
select sim.confere('o time respondeu: a situação gravada já é "esperando o cliente"',
  (select situacao from public.lead_estado where conversa_id = :'c') = 'time_esperando',
  (select situacao || ' · ' || coalesce(evento, '') from public.lead_estado where conversa_id = :'c'));
select sim.confere('e o prazo gravado já é o da cutucada (~3 h)',
  (select prazo_em from public.lead_estado where conversa_id = :'c') between now() + interval '2 hours 50 minutes' and now() + interval '3 hours 5 minutes',
  (select coalesce(prazo_em::text, 'vazio') from public.lead_estado where conversa_id = :'c'));
select sim.cliente_escreve(:'c', 'https://www.facebook.com/share/r/exemplo/', false) as r \gset
select sim.confere('o cliente escreveu: a situação gravada já é "responder agora", pelo evento do cliente',
  (select situacao from public.lead_estado where conversa_id = :'c') = 'time_agora'
  and exists (select 1 from public.lead_estado_mudancas m where m.conversa_id = :'c' and m.para = 'time_agora' and m.evento = 'cliente_escreveu'
                 and m.em > now() - interval '5 minutes'),
  (select situacao || ' · ' || coalesce(evento, '') from public.lead_estado where conversa_id = :'c'));
select sim.como('backoffice');
select public.backoffice_responder(:'c', 'Conseguiu ver o link? Me manda o CPF que eu sigo.');
select sim.fila_rodar();
select sim.como('servico');
select sim.confere('o time respondeu de novo: "esperando o cliente" na hora, pelo evento do time',
  (select situacao from public.lead_estado where conversa_id = :'c') = 'time_esperando'
  and (select evento from public.lead_estado where conversa_id = :'c') = 'time_respondeu',
  (select situacao || ' · ' || coalesce(evento, '') from public.lead_estado where conversa_id = :'c'));
