-- id: F1
-- titulo: Instalou: a mensagem de pós-instalação sai (mesmo com o time) e o time sai da conversa
-- tipo: atual
select sim.venda_pronta('Pia F1') as c \gset
select sim.como('backoffice');
select public.backoffice_momento(sim.venda(:'c'), 'os_agendar', jsonb_build_object('os', '89' || sim._conv(:'c'), 'dia', (current_date + 2)::text, 'periodo', '08:00', 'forma', 'boleto'));
select sim.fila_rodar();
select sim.passa(:'c', '2 days');   -- a instalação é dias depois do agendamento (a pós-instalação espera 2 h de qualquer fala do time)
select sim.instalou(:'c');
select count(*) as antes from sim.envios where conversa = :'c' \gset
select sim.espera(:'c', '90 minutes');
select sim.confere('o lead está em Instalada', sim.lead_de(:'c') ->> 'destino' = 'instalada', sim.lead_de(:'c')::text);
select sim.confere('a mensagem de pós-instalação saiu', (select count(*) from sim.envios where conversa = :'c') > :antes,
  (select string_agg(por || ': ' || left(texto, 40), ' | ' order by n) from sim.envios where conversa = :'c' and n > 0));
select sim.confere('o time saiu da conversa', sim.cw_de(:'c') ->> 'time' is null and sim.cw_de(:'c') ->> 'agente' is null, sim.cw_de(:'c')::text);
