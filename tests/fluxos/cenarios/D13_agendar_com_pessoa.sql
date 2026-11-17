-- id: D13
-- titulo: Agendar com uma pessoa conduzindo: o aviso sai em nome dela e ela continua dona da conversa
-- tipo: atual
select sim.venda_pronta('Mia D13', true) as c \gset
select sim.como('backoffice');
select public.backoffice_momento(sim.venda(:'c'), 'os', jsonb_build_object('os', '96' || sim._conv(:'c'), 'forma', 'boleto'));
select public.backoffice_momento(sim.venda(:'c'), 'agendar', jsonb_build_object('dia', (current_date + 4)::text, 'periodo', '08:00'));
select sim.fila_rodar();
select sim.confere('o aviso do agendamento saiu em nome da pessoa',
  exists (select 1 from sim.envios where conversa = :'c' and por = 'time'),
  (select coalesce(string_agg(por, ' ' order by n), 'nada') from sim.envios where conversa = :'c'));
select sim.como('servico');
select sim.espera(:'c', '20 minutes');
select sim.confere('20 min depois a pessoa continua dona da conversa', sim.cw_de(:'c') ->> 'agente' is not null and (sim.foto(:'c') ->> 'humano')::boolean,
  sim.cw_de(:'c')::text);
select sim.confere('a conversa não foi resolvida e reaberta (pisca)',
  not exists (select 1 from sim.trilha where o_que like '%status resolved → open%') ,
  (select string_agg(quem || ': ' || o_que, ' · ' order by n) from sim.trilha where o_que like '%status %→%'));
