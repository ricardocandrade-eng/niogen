-- id: B8
-- titulo: Cliente pede para falar daqui a 5 dias: espera com data, nada sai até lá, retorno às 9h
-- tipo: atual
select sim.lead_novo('Ula B8') as c \gset
select sim.cliente_escreve(:'c', 'agora não dá, me chama daqui uns 5 dias');
select sim.como('backoffice');
select public.backoffice_conversa_espera(:'c', current_date + 5, 'cliente pediu');
select sim.como('servico');
select sim.confere('o retorno é às 9h do dia', to_char((sim.foto(:'c') ->> 'espera_ate')::timestamptz at time zone 'America/Sao_Paulo', 'HH24:MI') = '09:00'
  or to_char((select espera_ate from public.mari_conversas where id = :'c') at time zone 'America/Sao_Paulo', 'HH24:MI') = '09:00',
  (select espera_ate::text from public.mari_conversas where id = :'c'));
select sim.silencio(:'c', 4);
select sim.confere('nada sai durante a espera', (select count(*) from sim.envios where conversa = :'c' and por like 'cadencia:%') = 0,
  (select coalesce(string_agg(por, ' '), 'nada') from sim.envios where conversa = :'c' and por like 'cadencia:%'));
select sim.passa(:'c', '1 day');
select count(*) as n3 from sim.cadencia(sim.hora('03:00')) x where x like '%enviado' \gset
select sim.confere('no dia do retorno, de madrugada, nada sai', :n3 = 0, 'envios às 3h: ' || :n3);
