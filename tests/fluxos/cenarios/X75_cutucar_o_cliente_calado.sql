-- id: X75
-- titulo: 0349 (caso L-233, 21/11): o time respondeu e o cliente ficou calado — 3 h depois, no horário do time e dentro da janela de 24 h, a vez volta ao time ("Cutucar o cliente") e a linha sobe para a Sua fila; o time cutuca e volta a esperar, sem nova cutucada; o prazo gravado é o da cutucada, não o do handoff
-- tipo: atual
-- Parte 1: o vencimento, com o horário padrão do time (seg–sex 9–21, sáb 10–16), em datas fixas.
select sim.como('servico');
delete from public.config_regras where chave in ('time_horario', 'cutucar_horas');
select sim.confere('dia útil, no horário: 3 h depois',
  public._cutucar_em('2026-11-18 10:00-03', '2026-11-19 09:00-03') = '2026-11-18 13:00-03'::timestamptz,
  public._cutucar_em('2026-11-18 10:00-03', '2026-11-19 09:00-03')::text);
select sim.confere('3 h cai depois das 21h: a próxima abertura (9h), antes de a janela fechar',
  public._cutucar_em('2026-11-18 19:30-03', '2026-11-19 19:00-03') = '2026-11-19 09:00-03'::timestamptz,
  public._cutucar_em('2026-11-18 19:30-03', '2026-11-19 19:00-03')::text);
select sim.confere('a próxima abertura já seria tarde (janela fecha sáb 10h15): antecipa para 15 min antes do fim do turno',
  public._cutucar_em('2026-11-20 19:30-03', '2026-11-21 10:15-03') = '2026-11-20 20:45-03'::timestamptz,
  public._cutucar_em('2026-11-20 19:30-03', '2026-11-21 10:15-03')::text);
select sim.confere('caso L-233: resposta sáb 21h28 (fora do horário), janela fecha dom 20h21 → sem cutucada (a Mari assume na janela)',
  public._cutucar_em('2026-11-21 21:28-03', '2026-11-22 20:21-03') is null,
  public._cutucar_em('2026-11-21 21:28-03', '2026-11-22 20:21-03')::text);

-- Parte 2: o fluxo, com o time aberto o dia todo (o cenário não depende da hora em que roda).
insert into public.config_regras (chave, valor, descricao) values
  ('time_horario', '{"1": [0, 24], "2": [0, 24], "3": [0, 24], "4": [0, 24], "5": [0, 24], "6": [0, 24], "7": [0, 24]}'::jsonb, 'X75: time aberto o dia todo')
on conflict (chave) do update set valor = excluded.valor;
select sim.lead_novo('Aparecida X75') as c \gset
select sim.mari_fala(:'c', 'Oi! Sou a Mari, da Dharma. Qual o seu CEP?');
select sim.como('backoffice');
select public.backoffice_conversa(:'c', 'atribuir', 'eu');
select sim.fila_rodar();
select sim.como('backoffice');
select public.backoffice_responder(:'c', 'Boa noite, Aparecida! Consigo te passar a data da instalação, me confirma o CPF?');
select sim.fila_rodar();
select sim.como('servico');
select coalesce((select situacao from public.v_lead_situacao where conversa_id = :'c'), '') as s1 \gset
select sim.confere('o time respondeu: esperando o cliente', :'s1' = 'time_esperando', :'s1');
select sim.tique();   -- a situação gravada acompanha na varredura de 10 min (como hoje)
select sim.confere('o prazo gravado é o da cutucada (~3 h), não o do handoff',
  (select prazo_em from public.lead_estado where conversa_id = :'c') between now() + interval '2 hours 50 minutes' and now() + interval '3 hours 5 minutes',
  (select prazo_em::text from public.lead_estado where conversa_id = :'c'));

select sim.espera(:'c', '2 hours');
select coalesce((select situacao from public.v_lead_situacao where conversa_id = :'c'), '') as s2 \gset
select sim.confere('2 h sem resposta: ainda esperando o cliente', :'s2' = 'time_esperando', :'s2');

select sim.espera(:'c', '70 minutes');
select coalesce((select situacao from public.v_lead_situacao where conversa_id = :'c'), '') as s3 \gset
select sim.confere('3 h sem resposta: a vez volta ao time (cutucar)', :'s3' = 'time_agora', :'s3');
select sim.confere('a situação gravada concorda, pelo relógio da porta (prazo:cutucar)',
  (select situacao from public.lead_estado where conversa_id = :'c') = 'time_agora'
  and exists (select 1 from public.lead_estado_mudancas m where m.conversa_id = :'c' and m.evento = 'prazo:cutucar' and m.para = 'time_agora'),
  (select situacao || ' · ' || coalesce(evento, '') from public.lead_estado where conversa_id = :'c'));
select sim.como('backoffice');
select coalesce((select x ->> 'o_que_fazer' from jsonb_array_elements(public.live_situacoes()) x where x ->> 'conversa_id' = :'c'), '') as t \gset
select sim.confere('a Live diz "Cutucar o cliente"', :'t' like 'Cutucar o cliente%', :'t');

select public.backoffice_responder(:'c', 'Aparecida, conseguiu ver? Posso seguir com o pedido?');
select sim.fila_rodar();
select sim.como('servico');
select coalesce((select situacao from public.v_lead_situacao where conversa_id = :'c'), '') as s4 \gset
select sim.confere('o time cutucou: volta a esperar o cliente', :'s4' = 'time_esperando', :'s4');
select sim.confere('o prazo agora é o fechamento da janela de 24 h',
  (select prazo_em from public.v_lead_situacao where conversa_id = :'c')
    = (select max(created_at) + interval '24 hours' from public.mari_turnos where conversa_id = :'c' and papel = 'lead'),
  (select prazo_em::text from public.v_lead_situacao where conversa_id = :'c'));

select sim.espera(:'c', '4 hours');
select coalesce((select situacao from public.v_lead_situacao where conversa_id = :'c'), '') as s5 \gset
select sim.confere('uma cutucada só: 4 h depois segue esperando o cliente', :'s5' = 'time_esperando', :'s5');

select sim.cliente_escreve(:'c', 'oi, vi agora') as r \gset
select sim.fila_rodar();
select coalesce((select situacao from public.v_lead_situacao where conversa_id = :'c'), '') as s6 \gset
select sim.confere('o cliente escreveu: responder agora', :'s6' = 'time_agora', :'s6');
select sim.como('backoffice');
select coalesce((select x ->> 'o_que_fazer' from jsonb_array_elements(public.live_situacoes()) x where x ->> 'conversa_id' = :'c'), '') as t2 \gset
select sim.confere('e a Live não diz mais "Cutucar"', :'t2' not like 'Cutucar%', :'t2');
